//
//  PhotoCompressor.swift
//  FFmpui (iOS)
//
//  The iOS version of VideoCompressor: a queue of Photos videos, each one
//  exported, encoded with the shared VideoTranscoder (same settings as the
//  Mac's AVFoundation encoder), given the original's metadata by
//  MetadataCopier, checked, and saved back to Photos.
//

import AVFoundation
import Foundation
import Observation
import Photos

struct PhotoItem: Identifiable, Equatable {
    enum Status: Equatable {
        case waiting
        case downloading
        case working
        case saving
        case done
        case failed(String)
        case skipped(String)
    }

    let id = UUID()
    let assetID: String
    var filename: String
    var status: Status = .waiting
    var progress: Double = 0
    var originalSize: Int64?
    var newSize: Int64?

    var isBusy: Bool {
        switch status {
        case .downloading, .working, .saving: true
        default: false
        }
    }
}

@Observable
final class PhotoCompressor {
    static let bitrate = VideoTranscoder.defaultBitrate

    var items: [PhotoItem] = []
    var replaceOriginals = false
    var highPriority = true
    private(set) var isRunning = false
    private(set) var log: [String] = []
    private(set) var access = PhotoLibrary.authorization

    private var currentTask: Task<Void, Error>?
    private var stopRequested = false
    private var originalsToDelete: [String] = []
    private let background = BackgroundRun()

    init() {
        background.onExpire = { [weak self] in
            self?.appendLog("iOS ended the background run.")
            self?.stop()
        }
    }

    // MARK: - Access

    var hasFullAccess: Bool { access == .authorized }

    func requestAccess() async {
        access = await PhotoLibrary.requestAccess()
    }

    func refreshAccess() {
        access = PhotoLibrary.authorization
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

    var canStart: Bool { !isRunning && pendingCount > 0 && hasFullAccess }

    func add(assetIDs: [String]) {
        var known = Set(items.map(\.assetID))
        for id in assetIDs where known.insert(id).inserted {
            items.append(PhotoItem(assetID: id, filename: PhotoLibrary.filename(id: id) ?? "Video"))
        }
    }

    func remove(_ item: PhotoItem) {
        guard !item.isBusy else { return }
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        guard !isRunning else { return }
        items.removeAll()
        log.removeAll()
    }

    // MARK: - Running

    func start() {
        guard canStart else { return }
        Task { await runQueue() }
    }

    func stop() {
        stopRequested = true
        currentTask?.cancel()
    }

    private func runQueue() async {
        isRunning = true
        stopRequested = false
        originalsToDelete = []
        log.removeAll()

        for index in items.indices {
            if case .failed = items[index].status { items[index].status = .waiting }
        }
        let total = items.filter { $0.status == .waiting }.count
        background.begin(total: total)
        var finished = 0

        while !stopRequested, let next = items.first(where: { $0.status == .waiting }) {
            await compress(next.id, finished: finished, total: total)
            finished += 1
        }

        // One deletion request for all replaced originals, so iOS asks once.
        if !originalsToDelete.isEmpty {
            do {
                try await PhotoLibrary.delete(ids: originalsToDelete)
                appendLog("Moved \(originalsToDelete.count) original\(originalsToDelete.count == 1 ? "" : "s") to Recently Deleted.")
            } catch {
                appendLog("Originals were kept: \(error.localizedDescription)")
            }
            originalsToDelete = []
        }

        background.end(success: !stopRequested)
        currentTask = nil
        isRunning = false
    }

    private func update(_ id: UUID, _ change: (inout PhotoItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func compress(_ id: UUID, finished: Int, total: Int) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        update(id) {
            $0.status = .downloading
            $0.progress = 0
            $0.newSize = nil
        }
        appendLog("▶︎ \(item.filename)")

        let progress: @Sendable (Double) -> Void = { value in
            Task { @MainActor in
                self.update(id) { $0.progress = value }
                let name = self.items.first(where: { $0.id == id })?.filename ?? ""
                self.background.update(done: Double(finished) + value, total: total,
                                       subtitle: "\(finished + 1) of \(total) · \(name)")
            }
        }

        let task = Task(priority: highPriority ? .userInitiated : .utility) {
            try await self.process(item, progress: progress)
        }
        currentTask = task
        do {
            try await task.value
        } catch {
            if stopRequested || error is CancellationError {
                update(id) {
                    $0.status = .waiting
                    $0.progress = 0
                }
                appendLog("■ Stopped")
            } else if case .skipped = items.first(where: { $0.id == id })?.status {
                // Reason already set.
            } else {
                update(id) { $0.status = .failed(error.localizedDescription) }
                appendLog("Error: \(error.localizedDescription)")
            }
        }
        currentTask = nil
    }

    private struct Skip: Error {}

    private func process(_ item: PhotoItem, progress: @escaping @Sendable (Double) -> Void) async throws {
        let id = item.id
        let original = try PhotoLibrary.original(id: item.assetID)
        if original.isEdited && replaceOriginals {
            update(id) { $0.status = .skipped("Edited in Photos. Turn off Replace to compress the unedited original.") }
            throw Skip()
        }
        if original.isEdited {
            appendLog("Note: \(original.filename) has edits in Photos; the unedited original is compressed.")
        }

        // Work in a private temp folder that is always cleaned up.
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("FFmpui", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outputFolder = work.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        if let size = original.fileSize,
           let free = try? work.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
               .volumeAvailableCapacityForImportantUsage,
           free < size * 2 + 200_000_000 {
            throw Failure.notEnoughSpace(needed: size * 2)
        }

        let filename = original.filename
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        let source = work.appendingPathComponent(filename)
        let newName = replaceOriginals ? filename : "\(name)_copy.\(ext)"
        let output = outputFolder.appendingPathComponent(newName)

        // 1. Original bytes (downloads from iCloud if needed)
        try await PhotoLibrary.export(original, to: source, progress: progress)
        let originalSize = fileSize(source)
        update(id) {
            $0.status = .working
            $0.progress = 0
            $0.originalSize = originalSize
        }

        // 2. Encode (same encoder and settings as the Mac)
        try await VideoTranscoder.transcode(
            source: source,
            destination: output,
            bitrate: Self.bitrate,
            log: { line in Task { @MainActor in self.appendLog(line) } },
            progress: progress
        )
        try Task.checkCancellation()

        // 3. Metadata: the original's boxes, byte for byte
        do {
            let notes = try MetadataCopier.copy(from: source, to: output)
            if !notes.isEmpty { appendLog("Metadata: " + notes.joined(separator: ", ")) }
        } catch {
            appendLog("Metadata: only the basic tags were kept (\(error.localizedDescription)).")
        }

        // 4. Check, like the script: it must open and be just as long.
        let before = try await duration(of: source)
        let after = try await duration(of: output)
        guard after > 0, abs(before - after) <= max(1.0, before * 0.01) else {
            throw Failure.checkFailed(before: before, after: after)
        }
        let newSize = fileSize(output)
        await logResult(output, size: newSize)

        // 5. Save to Photos
        update(id) { $0.status = .saving }
        _ = try await PhotoLibrary.save(output, filename: newName, like: original.asset)
        update(id) {
            $0.status = .done
            $0.progress = 1
            $0.newSize = newSize
        }
        if replaceOriginals { originalsToDelete.append(item.assetID) }
    }

    enum Failure: LocalizedError {
        case notEnoughSpace(needed: Int64)
        case checkFailed(before: Double, after: Double)

        var errorDescription: String? {
            switch self {
            case .notEnoughSpace(let needed):
                "Not enough free space (needs about \(needed.formatted(.byteCount(style: .file))))"
            case .checkFailed(let before, let after):
                "Output check failed (\(String(format: "%.1f", after)) s vs \(String(format: "%.1f", before)) s); original left untouched"
            }
        }
    }

    private func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    /// Same line as the Mac's Details log, for comparing results.
    private func logResult(_ output: URL, size: Int64?) async {
        var bitrate = "?"
        if let track = try? await AVURLAsset(url: output).loadTracks(withMediaType: .video).first,
           let rate = try? await track.load(.estimatedDataRate), rate > 0 {
            bitrate = String(format: "%.2f Mbit/s", Double(rate) / 1_000_000)
        }
        let sizeText = size.map { $0.formatted(.byteCount(style: .file)) } ?? "?"
        appendLog("✔︎ AVFoundation: \(output.lastPathComponent) · \(sizeText) · video \(bitrate)")
    }
}
