//
//  VideoCompressor.swift
//  FFmpui
//
//  Compresses each queued video and keeps track of progress so the UI can
//  show it:
//    1. encode: Size + Speed with the shared VideoTranscoder (like the iPhone
//       app); Size and Size + Quality with the bundled compress_video.sh
//       (ffmpeg / x265, --encode-only)
//    2. copy the original's metadata with the shared MetadataCopier (byte for
//       byte, like the iPhone app)
//    3. compress_video.sh --encoded: check it, copy Finder tags, permissions
//       and file dates, and move it into place
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
    }

    let id = UUID()
    let url: URL
    var status: Status = .waiting
    var progress: Double = 0
    var originalSize: Int64?
    var newSize: Int64?
    var outputURL: URL?
    /// What the script says it is doing (e.g. the quality search).
    var phase: String?
}

@Observable
final class VideoCompressor {
    enum Mode: String, CaseIterable, Identifiable {
        /// Apple's hardware encoder (shared VideoTranscoder, as on iPhone).
        case sizeAndSpeed
        /// x265, each video's quality setting found by a VMAF search.
        case sizeAndQuality
        /// x265, the smallest file possible.
        case size

        var id: String { rawValue }

        var label: String {
            switch self {
            case .sizeAndSpeed: "Size + Speed"
            case .sizeAndQuality: "Size + Quality"
            case .size: "Size"
            }
        }

        var caption: String {
            switch self {
            case .sizeAndSpeed:
                "The smallest file Apple's hardware encoder can make: fast, and the Mac stays cool. Frame rate capped at 24 fps. Same as the iPhone app."
            case .sizeAndQuality:
                "Looks like the original in as few bytes as possible: the best setting is found for each video. Same frame rate. Slow."
            case .size:
                "The smallest file possible, whatever it looks like. Frame rate capped at 24 fps."
            }
        }

        /// compress_video.sh's `--mode` (Size + Speed is encoded by the app
        /// itself and handed over with `--encoded`).
        var scriptMode: String {
            switch self {
            case .sizeAndSpeed: "speed"
            case .sizeAndQuality: "quality"
            case .size: "size"
            }
        }

        /// Encoded by x265 on the CPU, where High priority makes a difference.
        /// (The hardware encoder runs in a system process at its own pace.)
        var usesCPUEncoder: Bool { self != .sizeAndSpeed }
    }

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// Folders where Homebrew / MacPorts install command line tools.
    /// GUI apps don't get the shell's PATH, so we look in these explicitly.
    static let toolSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
    static let requiredTools = ["ffmpeg", "ffprobe"]

    private enum Key {
        static let replaceOriginals = "replaceOriginals"
        static let mode = "mode"
        static let scale = "scale"
        static let highPriority = "highPriority"
    }

    var items: [VideoItem] = []
    // Settings are remembered between launches.
    var replaceOriginals = false {
        didSet { UserDefaults.standard.set(replaceOriginals, forKey: Key.replaceOriginals) }
    }
    var mode: Mode = .sizeAndSpeed {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Key.mode) }
    }
    var scale: OutputScale = .full {
        didSet { UserDefaults.standard.set(scale.rawValue, forKey: Key.scale) }
    }
    /// x265 modes only. On: all of the Mac's power, like the script in
    /// Terminal. Off: efficiency cores only (cool and quiet, but slower).
    var highPriority = true {
        didSet { UserDefaults.standard.set(highPriority, forKey: Key.highPriority) }
    }
    private(set) var isRunning = false
    private(set) var log: [String] = []
    private(set) var missingTools: [String] = []

    private var currentProcess: Process?
    private var currentEncode: Task<Void, Error>?
    private var stopRequested = false

    init() {
        let defaults = UserDefaults.standard
        replaceOriginals = defaults.bool(forKey: Key.replaceOriginals)
        mode = defaults.string(forKey: Key.mode).flatMap(Mode.init(rawValue:)) ?? .sizeAndSpeed
        scale = OutputScale(rawValue: defaults.double(forKey: Key.scale)) ?? .full
        highPriority = defaults.object(forKey: Key.highPriority) as? Bool ?? true
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
            // Skip results of a previous run ("_copy_avf": older versions).
            let name = file.deletingPathExtension().lastPathComponent
            if name.hasSuffix("_copy") || name.hasSuffix("_copy_avf") { continue }
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
            $0.phase = nil
        }
        appendLog("▶︎ \(item.url.path)")

        let mode = self.mode
        let replace = replaceOriginals ? ["--replace"] : []

        // 1. Encode
        let encoded: URL
        if mode == .sizeAndSpeed {
            guard let file = await encodeWithAVFoundation(item) else { return }
            encoded = file
        } else {
            let arguments = replace + ["--mode", mode.scriptMode, "--scale", scale.argument,
                                       "--encode-only", "--", item.url.path]
            guard let file = await runScript(script, arguments: arguments, for: id, cpuHeavy: true) else {
                update(id) { $0.phase = nil }
                return
            }
            encoded = file
        }
        update(id) { $0.phase = nil }

        // 2. Metadata
        await copyMetadata(from: item.url, to: encoded)
        if stopRequested {
            try? FileManager.default.removeItem(at: encoded)
            update(id) {
                $0.status = .waiting
                $0.progress = 0
            }
            appendLog("■ Stopped")
            return
        }

        // 3. Check, file attributes, move into place
        await runScript(script, arguments: replace + ["--encoded", encoded.path, "--", item.url.path],
                        for: id, cpuHeavy: false)

        if let output = items.first(where: { $0.id == id })?.outputURL,
           items.first(where: { $0.id == id })?.status == .done {
            await logResult(output, mode: mode)
        }
    }

    /// The original's metadata, byte for byte (the same MetadataCopier as
    /// the iPhone app): dates, Apple Keys (GPS, camera, lens …), UserData,
    /// XMP, maker blocks, per-track metadata; it also fits the rotation
    /// offset to a scaled picture.
    private func copyMetadata(from source: URL, to output: URL) async {
        let result = await Task.detached { () -> Result<[String], Error> in
            Result { try MetadataCopier.copy(from: source, to: output) }
        }.value
        switch result {
        case .success(let notes):
            if !notes.isEmpty { appendLog("Metadata: " + notes.joined(separator: ", ")) }
        case .failure(let error):
            appendLog("Metadata: only the basic tags were kept (\(error.localizedDescription)).")
        }
    }

    /// Size + Speed: runs VideoTranscoder into the same hidden temp file name
    /// the script would use. Returns nil (with the item's status set) on
    /// failure or Stop.
    private func encodeWithAVFoundation(_ item: VideoItem) async -> URL? {
        let id = item.id
        let source = item.url
        let name = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let tempName = replaceOriginals
            ? ".\(name).ffmpui-tmp.\(ext)"
            : ".\(name)_copy.ffmpui-tmp.\(ext)"
        let destination = source.deletingLastPathComponent().appendingPathComponent(tempName)
        let settings = VideoTranscoder.Settings.sizeAndSpeed(scale: scale.rawValue)

        let task = Task {
            try await VideoTranscoder.transcode(
                source: source,
                destination: destination,
                settings: settings,
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
                update(id) { $0.status = .failed("Could not encode this file: \(error.localizedDescription)") }
                appendLog("Encoder error: \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// Runs compress_video.sh for one file and turns its output into status,
    /// progress and log lines. With --encode-only, returns the encoded file
    /// (and leaves the status to the caller); nil if it failed or was stopped.
    @discardableResult
    private func runScript(_ script: URL, arguments: [String], for id: UUID, cpuHeavy: Bool) async -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        // Only x265 is CPU-heavy: there, low priority keeps it on the
        // efficiency cores. The rest (checks, moving files) runs at full speed.
        process.qualityOfService = cpuHeavy && !highPriority ? .background : .userInitiated

        do {
            try process.run()
        } catch {
            update(id) { $0.status = .failed("Could not start: \(error.localizedDescription)") }
            return nil
        }
        currentProcess = process

        var duration: Double = 0
        var result: VideoItem.Status?
        var encoded: URL?

        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                if line.hasPrefix("@@DURATION ") {
                    duration = Double(line.dropFirst("@@DURATION ".count)) ?? 0
                } else if line.hasPrefix("@@PHASE ") {
                    let phase = String(line.dropFirst("@@PHASE ".count))
                    update(id) { $0.phase = phase }
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
                } else if line.hasPrefix("@@ENCODED ") {
                    encoded = URL(fileURLWithPath: String(line.dropFirst("@@ENCODED ".count)))
                } else if line.hasPrefix("@@FILE_FAIL ") {
                    result = .failed(String(line.dropFirst("@@FILE_FAIL ".count)))
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

        if let encoded {
            if !stopRequested && result == nil && process.terminationStatus == 0 { return encoded }
            try? FileManager.default.removeItem(at: encoded)
        }

        if stopRequested && result == nil {
            update(id) {
                $0.status = .waiting
                $0.progress = 0
            }
            appendLog("■ Stopped")
            return nil
        }

        let finalStatus = result ?? .failed("Stopped unexpectedly (exit code \(process.terminationStatus))")
        update(id) {
            $0.status = finalStatus
            if finalStatus == .done { $0.progress = 1 }
        }
        return nil
    }

    /// One line per finished file: mode, file size and the video track's
    /// average bitrate.
    private func logResult(_ output: URL, mode: Mode) async {
        let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            Int64($0).formatted(.byteCount(style: .file))
        } ?? "?"
        var bitrate = "?"
        if let track = try? await AVURLAsset(url: output).loadTracks(withMediaType: .video).first,
           let rate = try? await track.load(.estimatedDataRate), rate > 0 {
            bitrate = String(format: "%.2f Mbit/s", Double(rate) / 1_000_000)
        }
        appendLog("✔︎ \(mode.label): \(output.lastPathComponent) · \(size) · video \(bitrate)")
    }

    /// ffmpeg's `-progress` output is a series of `key=value` lines.
    private static func isFFmpegProgressLine(_ line: String) -> Bool {
        guard let equals = line.firstIndex(of: "=") else { return false }
        let key = line[..<equals]
        return !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
