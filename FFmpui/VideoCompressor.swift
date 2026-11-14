//
//  VideoCompressor.swift
//  FFmpui
//
//  Runs the bundled compress_video.sh script on each queued video and keeps
//  track of progress so the UI can show it.
//

import AVFoundation
import Foundation
import Observation

struct VideoItem: Identifiable, Equatable {
    enum Status: Equatable {
        case waiting
        case working
        case done
        case failed(String)
        case skipped(String)
    }

    let id = UUID()
    let url: URL
    var status: Status = .waiting
    var progress: Double = 0
    var originalSize: Int64?
    var newSize: Int64?
    var outputURL: URL?
}

@Observable
final class VideoCompressor {
    enum Encoder {
        /// ffmpeg's hevc_videotoolbox, run by compress_video.sh.
        case ffmpeg
        /// AVFoundation (VideoTranscoder.swift), then the script's metadata step.
        case avfoundation
    }

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    /// Name ending of AVFoundation results, so they can sit next to
    /// ffmpeg's "_copy" files for comparison.
    static let avfoundationSuffix = "_copy_avf"
    static let avfoundationBitrate = VideoTranscoder.defaultBitrate

    /// Folders where Homebrew / MacPorts install command line tools.
    /// GUI apps don't get the shell's PATH, so we look in these explicitly.
    static let toolSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
    static let requiredTools = ["ffmpeg", "ffprobe", "exiftool"]

    var items: [VideoItem] = []
    var replaceOriginals = false
    /// On: encode at the same high priority as a command typed in Terminal,
    /// even when the app is in the background. Off: let other apps go first.
    var highPriority = true
    var encoder: Encoder = .ffmpeg
    private(set) var isRunning = false
    private(set) var log: [String] = []
    private(set) var missingTools: [String] = []

    private var currentProcess: Process?
    private var currentEncode: Task<Void, Error>?
    private var stopRequested = false

    init() {
        refreshToolCheck()
    }

    // MARK: - Queue

    var pendingCount: Int {
        items.filter { item in
            switch item.status {
            case .waiting, .failed: true
            default: false
            }
        }.count
    }

    var canStart: Bool { !isRunning && pendingCount > 0 && missingTools.isEmpty }

    /// Adds files and/or folders. Folders are searched recursively for videos.
    func add(urls: [URL]) {
        var known = Set(items.map { $0.url.standardizedFileURL.path })
        for url in urls {
            for video in Self.videos(in: url) {
                let path = video.standardizedFileURL.path
                if known.insert(path).inserted {
                    items.append(VideoItem(url: video))
                }
            }
        }
    }

    func remove(_ item: VideoItem) {
        guard item.status != .working else { return }
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        guard !isRunning else { return }
        items.removeAll()
        log.removeAll()
    }

    private static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    private static func videos(in url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }

        guard isDirectory.boolValue else {
            return isVideo(url) ? [url] : []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        for case let file as URL in enumerator {
            guard isVideo(file) else { continue }
            // Skip results of a previous run.
            let name = file.deletingPathExtension().lastPathComponent
            if name.hasSuffix("_copy") || name.hasSuffix(avfoundationSuffix) { continue }
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                found.append(file)
            }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - Tools

    func refreshToolCheck() {
        missingTools = Self.requiredTools.filter { tool in
            !Self.toolSearchPaths.contains { dir in
                FileManager.default.isExecutableFile(atPath: "\(dir)/\(tool)")
            }
        }
    }

    // MARK: - Running

    func start() {
        guard canStart else { return }
        Task { await runQueue() }
    }

    func stop() {
        stopRequested = true
        currentEncode?.cancel()
        currentProcess?.terminate()
    }

    private func runQueue() async {
        isRunning = true
        stopRequested = false
        log.removeAll()

        // Keep the Mac awake while compressing.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Compressing videos"
        )
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            currentProcess = nil
            isRunning = false
        }

        // Give previously failed files another try.
        for index in items.indices {
            if case .failed = items[index].status { items[index].status = .waiting }
        }

        while !stopRequested, let next = items.first(where: { $0.status == .waiting }) {
            await compress(next.id)
        }
    }

    private func update(_ id: UUID, _ change: (inout VideoItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func compress(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }

        guard let script = Bundle.main.url(forResource: "compress_video", withExtension: "sh") else {
            update(id) { $0.status = .failed("compress_video.sh is missing from the app bundle") }
            stopRequested = true
            return
        }

        update(id) {
            $0.status = .working
            $0.progress = 0
            $0.newSize = nil
            $0.outputURL = nil
        }
        appendLog("▶︎ \(item.url.path)")

        var arguments = replaceOriginals ? ["--replace"] : []
        if encoder == .avfoundation {
            // Encode here, then let the script check the result, copy the
            // metadata / file attributes and move it into place.
            guard let encoded = await encodeWithAVFoundation(item) else { return }
            arguments += ["--encoded", encoded.path, "--suffix", Self.avfoundationSuffix]
        }

        await runScript(script, arguments: arguments + ["--", item.url.path], for: id)

        if let output = items.first(where: { $0.id == id })?.outputURL,
           items.first(where: { $0.id == id })?.status == .done {
            await logResult(output)
        }
    }

    /// Runs VideoTranscoder into the same hidden temp file name the script
    /// would use. Returns nil (with the item's status set) on failure or Stop.
    private func encodeWithAVFoundation(_ item: VideoItem) async -> URL? {
        let id = item.id
        let source = item.url
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let tempName = replaceOriginals
            ? ".\(name).ffmpui-tmp.\(ext)"
            : ".\(name)\(Self.avfoundationSuffix).ffmpui-tmp.\(ext)"
        let destination = source.deletingLastPathComponent().appendingPathComponent(tempName)

        let task = Task(priority: highPriority ? .userInitiated : .utility) {
            try await VideoTranscoder.transcode(
                source: source,
                destination: destination,
                bitrate: Self.avfoundationBitrate,
                log: { line in Task { @MainActor in self.appendLog(line) } },
                progress: { value in Task { @MainActor in self.update(id) { $0.progress = value } } }
            )
        }
        currentEncode = task
        defer { currentEncode = nil }

        do {
            try await task.value
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if stopRequested {
                update(id) {
                    $0.status = .waiting
                    $0.progress = 0
                }
                appendLog("■ Stopped")
            } else {
                update(id) { $0.status = .failed("AVFoundation could not encode this file: \(error.localizedDescription)") }
                appendLog("AVFoundation error: \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// Runs compress_video.sh for one file and turns its output into status,
    /// progress and log lines.
    private func runScript(_ script: URL, arguments: [String], for id: UUID) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = highPriority ? .userInitiated : .utility

        do {
            try process.run()
        } catch {
            update(id) { $0.status = .failed("Could not start: \(error.localizedDescription)") }
            return
        }
        currentProcess = process

        var duration: Double = 0
        var result: VideoItem.Status?

        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                if line.hasPrefix("@@DURATION ") {
                    duration = Double(line.dropFirst("@@DURATION ".count)) ?? 0
                } else if line.hasPrefix("out_time_us=") {
                    if duration > 0, let micros = Double(line.dropFirst("out_time_us=".count)) {
                        let value = min(max(micros / 1_000_000 / duration, 0), 1)
                        update(id) { $0.progress = value }
                    }
                } else if line.hasPrefix("@@FILE_DONE ") {
                    let parts = line.dropFirst("@@FILE_DONE ".count).split(separator: " ", maxSplits: 2)
                    if parts.count == 3 {
                        let original = Int64(parts[0])
                        let new = Int64(parts[1])
                        let output = URL(fileURLWithPath: String(parts[2]))
                        update(id) {
                            $0.originalSize = original
                            $0.newSize = new
                            $0.outputURL = output
                        }
                    }
                    result = .done
                } else if line.hasPrefix("@@FILE_FAIL ") {
                    result = .failed(String(line.dropFirst("@@FILE_FAIL ".count)))
                } else if line.hasPrefix("@@FILE_SKIP ") {
                    result = .skipped(String(line.dropFirst("@@FILE_SKIP ".count)))
                } else if line.hasPrefix("@@") || Self.isFFmpegProgressLine(line) {
                    continue
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    appendLog(line)
                }
            }
        } catch {
            appendLog("Error reading output: \(error.localizedDescription)")
        }

        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        currentProcess = nil

        if stopRequested && result == nil {
            update(id) {
                $0.status = .waiting
                $0.progress = 0
            }
            appendLog("■ Stopped")
            return
        }

        let finalStatus = result ?? .failed("Stopped unexpectedly (exit code \(process.terminationStatus))")
        update(id) {
            $0.status = finalStatus
            if finalStatus == .done { $0.progress = 1 }
        }
    }

    /// One line per finished file to compare the two encoders:
    /// encoder, file size and the video track's average bitrate.
    private func logResult(_ output: URL) async {
        let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            Int64($0).formatted(.byteCount(style: .file))
        } ?? "?"
        var bitrate = "?"
        if let track = try? await AVURLAsset(url: output).loadTracks(withMediaType: .video).first,
           let rate = try? await track.load(.estimatedDataRate), rate > 0 {
            bitrate = String(format: "%.2f Mbit/s", Double(rate) / 1_000_000)
        }
        let label = encoder == .avfoundation ? "AVFoundation" : "ffmpeg"
        appendLog("✔︎ \(label): \(output.lastPathComponent) · \(size) · video \(bitrate)")
    }

    /// ffmpeg's `-progress` output is a series of `key=value` lines.
    private static func isFFmpegProgressLine(_ line: String) -> Bool {
        guard let equals = line.firstIndex(of: "=") else { return false }
        let key = line[..<equals]
        return !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
