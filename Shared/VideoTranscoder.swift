//
//  VideoTranscoder.swift
//  FFmpui
//
//  Re-encodes a video to HEVC with AVFoundation (Apple's VideoToolbox
//  hardware encoder). This is the "Size + Speed" mode of both apps: the
//  smallest file the hardware encoder makes, quickly and without much heat.
//
//    • first video track → HEVC at the lowest bitrate, optionally scaled,
//      frame rate capped at 24 fps, rotation flag kept (pixels not rotated)
//    • every audio track copied untouched
//    • timecode / metadata / telemetry / subtitle tracks copied when the
//      container accepts them, otherwise a second try with video + audio only
//
//  The original's metadata is copied afterwards: on the Mac by the script's
//  ExifTool step (`compress_video.sh --encoded`), exactly as for the ffmpeg
//  encoder; on iOS by MetadataCopier. Shared by both apps.
//

import AVFoundation
import CoreMedia
import VideoToolbox

nonisolated enum VideoTranscoder {
    enum Failure: LocalizedError {
        case noVideoTrack
        case unsupportedSettings
        case cannotAdd(String)
        case readFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The file has no video track"
            case .unsupportedSettings: "The HEVC encoder settings were rejected"
            case .cannotAdd(let what): "Can't write \(what) into this container"
            case .readFailed(let reason): "Reading failed: \(reason)"
            case .writeFailed(let reason): "Writing failed: \(reason)"
            }
        }
    }

    struct Settings: Sendable {
        enum KeyFrames: Sendable, Equatable {
            /// At most this many seconds apart.
            case every(Double)
            /// Only the first frame is a keyframe (the encoder may still add
            /// one where that makes the file smaller, e.g. at a scene cut).
            case single
            /// No limit set: the encoder decides where to put them.
            case encoderChoice
        }

        /// Width and height factor (1, 0.5, 0.25), rounded down to even sizes.
        var scale: Double = 1
        /// Frames above this rate are dropped; nil keeps every frame.
        var maxFrameRate: Double? = 24
        /// 1 asks VideoToolbox for the lowest bitrate it can do.
        var bitrate: Int? = 1
        /// Constant-quality target (0…1): 0 shaves off another ~1%. Never used
        /// alone: an encoder that ignored it would fall back to a high default
        /// bitrate, so the lowest bitrate and the quantizer floor stay too.
        var quality: Double? = 0
        /// Keyframes are the biggest frames, so fewer keep the file small;
        /// 10 s still seeks quickly.
        var keyFrames: KeyFrames = .every(10)
        /// Ask the encoder to use as little power as it can (less heat).
        var powerEfficient = true
        /// Ask the encoder to favor speed over quality (experiment: at the
        /// lowest bitrate it can make *bigger* files, like faster x265 presets).
        var prioritizeSpeed = false
        /// Lowest quantizer the encoder may use (51 = HEVC's coarsest). The
        /// lowest bitrate alone leaves the hardware encoder well above it:
        /// this makes the video about 4× smaller (Tests/run_transcoder.sh).
        var minFrameQP: Int? = 51
        /// Let the encoder vary the quantizer within a frame (detail vs. flat
        /// areas). Off saves another ~10% when quality doesn't matter.
        /// (Mac only; iOS has no such setting.)
        var adaptiveQP = false

        /// Both apps' "Size + Speed" mode.
        static func sizeAndSpeed(scale: Double) -> Settings {
            Settings(scale: scale)
        }
    }

    /// Container of the output, chosen by the file extension (like ffmpeg).
    static func fileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mov": .mov
        case "m4v": .m4v
        default: .mp4
        }
    }

    /// Encodes `source` into `destination` (overwritten if it exists).
    /// Cancel the calling task to stop; the partial file is deleted.
    @concurrent
    static func transcode(
        source: URL,
        destination: URL,
        settings: Settings,
        log: @escaping @Sendable (String) -> Void,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw Failure.noVideoTrack
        }
        let hasOtherTracks = tracks.contains(where: isOtherTrack)

        do {
            try await encode(asset: asset, tracks: tracks, videoTrack: videoTrack, destination: destination,
                             settings: settings, includeOtherTracks: hasOtherTracks, log: log, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            guard hasOtherTracks, !(error is CancellationError), !Task.isCancelled else { throw error }
            // Same fallback as the script: some data tracks can't be written
            // into every container.
            log("Note: some data tracks could not be kept for '\(source.lastPathComponent)' "
                + "(\(error.localizedDescription)); retrying with video + audio only.")
            progress(0)
            do {
                try await encode(asset: asset, tracks: tracks, videoTrack: videoTrack, destination: destination,
                                 settings: settings, includeOtherTracks: false, log: { _ in }, progress: progress)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }

    /// Tracks that ffmpeg's attempt 1 maps besides video and audio: data
    /// tracks (timecode, metadata, telemetry) and subtitles. Extra video
    /// tracks are left out, like `-map 0:V:0`.
    private static func isOtherTrack(_ track: AVAssetTrack) -> Bool {
        switch track.mediaType {
        case .video, .audio: false
        default: true
        }
    }

    // MARK: - One attempt

    private struct Pair {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let isVideo: Bool
        /// Video only: keep at most this many frames per second.
        var maxFrameRate: Double?
    }

    private static func encode(
        asset: AVURLAsset,
        tracks: [AVAssetTrack],
        videoTrack: AVAssetTrack,
        destination: URL,
        settings: Settings,
        includeOtherTracks: Bool,
        log: @escaping @Sendable (String) -> Void,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: destination)

        let fileType = fileType(for: destination)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        writer.metadata = try await containerMetadata(of: asset, for: fileType)

        var pairs: [Pair] = []
        var inputsByTrackID: [CMPersistentTrackID: AVAssetWriterInput] = [:]
        var includedTracks: [AVAssetTrack] = []

        // Video → HEVC
        let (video, summary) = try await videoPair(for: videoTrack, reader: reader, writer: writer, settings: settings)
        log(summary)
        guard reader.canAdd(video.output) else { throw Failure.readFailed("can't decode the video track") }
        guard writer.canAdd(video.input) else { throw Failure.cannotAdd("the HEVC video track") }
        reader.add(video.output)
        writer.add(video.input)
        pairs.append(video)
        inputsByTrackID[videoTrack.trackID] = video.input
        includedTracks.append(videoTrack)

        // Audio (copied) and, on the first try, every other non-video track.
        for track in tracks where track.trackID != videoTrack.trackID {
            let isAudio = track.mediaType == .audio
            guard isAudio || (includeOtherTracks && isOtherTrack(track)) else { continue }

            let formats = try await track.load(.formatDescriptions)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil,
                                           sourceFormatHint: formats.first)
            input.expectsMediaDataInRealTime = false
            try await copyTrackProperties(from: track, to: input)

            let what = isAudio ? "an audio track" : "a \(track.mediaType.rawValue) track"
            guard reader.canAdd(output) else { throw Failure.readFailed("can't read \(what)") }
            guard writer.canAdd(input) else { throw Failure.cannotAdd(what) }
            reader.add(output)
            writer.add(input)
            pairs.append(Pair(output: output, input: input, isVideo: false))
            inputsByTrackID[track.trackID] = input
            includedTracks.append(track)
        }

        // Keep links such as "timecode for this video" or "metadata about
        // this video" between the copied tracks.
        for track in includedTracks {
            guard let input = inputsByTrackID[track.trackID] else { continue }
            for type in try await track.load(.availableTrackAssociationTypes) {
                for other in try await track.loadAssociatedTracks(ofType: type) {
                    guard let otherInput = inputsByTrackID[other.trackID],
                          input.canAddTrackAssociation(withTrackOf: otherInput, type: type.rawValue)
                    else { continue }
                    input.addTrackAssociation(withTrackOf: otherInput, type: type.rawValue)
                }
            }
        }

        let duration = try await asset.load(.duration).seconds

        guard reader.startReading() else {
            throw Failure.readFailed(reader.error?.localizedDescription ?? "unknown error")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw Failure.writeFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        do {
            try await pump(pairs, reader: reader, writer: writer, duration: duration, progress: progress)
        } catch {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure.writeFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        progress(1)
    }

    /// Feeds every track to the writer, round-robin, so the writer can
    /// interleave them. Checks for cancellation between passes.
    private static func pump(
        _ pairs: [Pair],
        reader: AVAssetReader,
        writer: AVAssetWriter,
        duration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var active = Array(repeating: true, count: pairs.count)
        var lastReported = -1.0
        // Frame rate cap: keep the first frame of every 1/rate-second slot,
        // like ffmpeg's fps filter. Kept frames keep their own timestamps.
        var firstVideoTime: Double?
        var lastSlot = Int.min

        while active.contains(true) {
            try Task.checkCancellation()
            var didWork = false

            for (index, pair) in pairs.enumerated() where active[index] {
                while pair.input.isReadyForMoreMediaData {
                    guard let sample = pair.output.copyNextSampleBuffer() else {
                        if reader.status == .failed {
                            throw Failure.readFailed(reader.error?.localizedDescription ?? "unknown error")
                        }
                        pair.input.markAsFinished()
                        active[index] = false
                        break
                    }
                    if pair.isVideo {
                        let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if duration > 0 {
                            let value = min(max(seconds / duration, 0), 1)
                            if value - lastReported >= 0.002 {
                                lastReported = value
                                progress(value)
                            }
                        }
                        if let rate = pair.maxFrameRate, seconds.isFinite {
                            let start = firstVideoTime ?? seconds
                            firstVideoTime = start
                            let slot = Int(((seconds - start) * rate + 1e-6).rounded(.down))
                            if slot == lastSlot {
                                didWork = true
                                continue  // dropped
                            }
                            lastSlot = slot
                        }
                    }
                    guard pair.input.append(sample) else {
                        throw Failure.writeFailed(writer.error?.localizedDescription ?? "unknown error")
                    }
                    didWork = true
                }
            }

            if writer.status == .failed {
                throw Failure.writeFailed(writer.error?.localizedDescription ?? "unknown error")
            }
            if !didWork {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    // MARK: - Settings

    /// Builds the decoder output and HEVC encoder input for the video track.
    /// Returns them with a one-line summary of the encoder settings for the log.
    private static func videoPair(
        for track: AVAssetTrack,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        settings: Settings
    ) async throws -> (Pair, String) {
        let (formats, naturalSize, transform, timeScale, frameRate) = try await track.load(
            .formatDescriptions, .naturalSize, .preferredTransform, .naturalTimeScale, .nominalFrameRate)
        let extensions = formats.first.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] } ?? [:]

        // Keep 10-bit / HDR (HLG, PQ) sources 10-bit.
        let bits = (extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber)?.intValue ?? 8
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let hdrTransfers = [kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
                            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String]
        let tenBit = bits > 8 || hdrTransfers.contains(transfer ?? "")

        // Output size: scaled, rounded down to even numbers (4:2:0 video).
        let sourceWidth = Int(naturalSize.width.rounded())
        let sourceHeight = Int(naturalSize.height.rounded())
        let isScaled = settings.scale < 1
        let width = isScaled ? evenSize(Double(sourceWidth) * settings.scale) : sourceWidth
        let height = isScaled ? evenSize(Double(sourceHeight) * settings.scale) : sourceHeight

        // Ask the decoder for frames at the output size (less memory traffic);
        // the encoder scales them itself if the decoder can't.
        var pixelSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: tenBit
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var output = AVAssetReaderTrackOutput(track: track, outputSettings: pixelSettings)
        if isScaled {
            pixelSettings[kCVPixelBufferWidthKey as String] = width
            pixelSettings[kCVPixelBufferHeightKey as String] = height
            let scaledOutput = AVAssetReaderTrackOutput(track: track, outputSettings: pixelSettings)
            if reader.canAdd(scaledOutput) { output = scaledOutput }
        }
        output.alwaysCopiesSampleData = false

        let outputRate: Double? = frameRate > 0
            ? min(Double(frameRate), settings.maxFrameRate ?? .infinity)
            : nil
        var compression: [String: Any] = [
            AVVideoProfileLevelKey: tenBit
                ? kVTProfileLevel_HEVC_Main10_AutoLevel as String
                : kVTProfileLevel_HEVC_Main_AutoLevel as String,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if let bitrate = settings.bitrate {
            compression[AVVideoAverageBitRateKey] = bitrate
        }
        if let quality = settings.quality {
            compression[AVVideoQualityKey] = quality
        }
        if let outputRate {
            compression[AVVideoExpectedSourceFrameRateKey] = outputRate
        }
        // "Single" is a 24-hour interval: no video is that long.
        let keyFrameSeconds: Double? = switch settings.keyFrames {
        case .every(let seconds): seconds
        case .single: 86_400
        case .encoderChoice: nil
        }
        if let keyFrameSeconds {
            compression[AVVideoMaxKeyFrameIntervalDurationKey] = keyFrameSeconds
            if let outputRate {
                compression[AVVideoMaxKeyFrameIntervalKey] = max(1, Int((outputRate * keyFrameSeconds).rounded()))
            }
        }

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if isScaled {
            videoSettings[AVVideoScalingModeKey] = AVVideoScalingModeResize
        }
        if let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
           let transfer,
           let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String {
            videoSettings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: matrix,
            ]
            if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
                videoSettings[AVVideoColorPropertiesKey] = nil
            }
        }
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw Failure.unsupportedSettings
        }

        // Encoder hints that not every device / OS accepts: each is only
        // added if the settings stay valid with it.
        var hints: [(key: String, value: Any, label: String)] = [
            (kVTCompressionPropertyKey_RealTime as String, false, "not real-time"),
        ]
        if settings.powerEfficient {
            hints.append((kVTCompressionPropertyKey_MaximizePowerEfficiency as String, true, "power-saving"))
        }
        if settings.prioritizeSpeed {
            hints.append((kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String, true, "speed over quality"))
        }
        if let qp = settings.minFrameQP {
            hints.append((kVTCompressionPropertyKey_MinAllowedFrameQP as String, qp, "QP ≥ \(qp)"))
        }
        #if os(macOS)  // not available on iOS
        if !settings.adaptiveQP {
            hints.append((kVTCompressionPropertyKey_SpatialAdaptiveQPLevel as String,
                          kVTQPModulationLevel_Disable, "no adaptive QP"))
        }
        #endif
        var applied: [String] = []
        for hint in hints {
            var trialCompression = compression
            trialCompression[hint.key] = hint.value
            var trial = videoSettings
            trial[AVVideoCompressionPropertiesKey] = trialCompression
            if writer.canApply(outputSettings: trial, forMediaType: .video) {
                compression = trialCompression
                videoSettings = trial
                applied.append(hint.label)
            }
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        // Rotation flag, like ffmpeg's -noautorotate + copied display matrix.
        // Its offset depends on the frame size, so it is redone when scaling.
        input.transform = isScaled ? fitted(transform, width: width, height: height) : transform
        if timeScale > 0 { input.mediaTimeScale = timeScale }
        try await copyTrackProperties(from: track, to: input)

        let maxRate = settings.maxFrameRate.flatMap { cap in frameRate > Float(cap) + 0.05 ? cap : nil }
        var summary = "Encoder: HEVC \(width)×\(height)\(tenBit ? " 10-bit" : "")"
        if let maxRate {
            summary += String(format: ", %.3g → %.3g fps", frameRate, maxRate)
        }
        if settings.bitrate != nil { summary += ", lowest bitrate" }
        if let quality = settings.quality { summary += String(format: ", quality %.2f", quality) }
        switch settings.keyFrames {
        case .every(let seconds): summary += String(format: ", keyframe every %.3g s", seconds)
        case .single: summary += ", single keyframe"
        case .encoderChoice: summary += ", keyframes where the encoder wants"
        }
        if !applied.isEmpty { summary += ", " + applied.joined(separator: ", ") }

        return (Pair(output: output, input: input, isVideo: true, maxFrameRate: maxRate), summary)
    }

    private static func evenSize(_ value: Double) -> Int {
        max(2, Int(value / 2) * 2)
    }

    /// The same rotation / flip, with the offset that moves the turned frame
    /// back to (0, 0) for a `width` × `height` frame (e.g. tx = height for a
    /// 90° turn, as cameras write it).
    static func fitted(_ transform: CGAffineTransform, width: Int, height: Int) -> CGAffineTransform {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0),
                       CGPoint(x: 0, y: height), CGPoint(x: width, y: height)]
        var rotation = transform
        rotation.tx = 0
        rotation.ty = 0
        let turned = corners.map { $0.applying(rotation) }
        rotation.tx = -(turned.map(\.x).min() ?? 0)
        rotation.ty = -(turned.map(\.y).min() ?? 0)
        return rotation
    }

    private static func copyTrackProperties(from track: AVAssetTrack, to input: AVAssetWriterInput) async throws {
        let (language, extendedLanguage) = try await track.load(.languageCode, .extendedLanguageTag)
        if let language { input.languageCode = language }
        if let extendedLanguage { input.extendedLanguageTag = extendedLanguage }
    }

    /// Movie-level tags the container can hold. Afterwards ExifTool (Mac) or
    /// MetadataCopier (iOS) copies the original's metadata boxes as well;
    /// this is the baseline, plus the mirrored Apple Keys below.
    private static func containerMetadata(of asset: AVURLAsset, for fileType: AVFileType) async throws -> [AVMetadataItem] {
        let keySpaces: Set<AVMetadataKeySpace> = fileType == .mov
            ? [.quickTimeMetadata, .quickTimeUserData]
            : [.iTunes, .isoUserData]
        let items = try await asset.load(.metadata)
        var result = items.filter { item in
            item.keySpace.map(keySpaces.contains) ?? false
        }
        if fileType == .mov {
            result += try await mirroredKeys(of: asset, existing: items)
        }
        return result
    }

    /// Many cameras store make / model / software / date / GPS only as
    /// QuickTime UserData or iTunes tags. Photos and Finder read Apple Keys
    /// first, so add Keys for whatever the original has elsewhere but not
    /// as Keys (the same idea as the script's '-Keys:Make<Make' mirroring).
    private static func mirroredKeys(of asset: AVURLAsset, existing: [AVMetadataItem]) async throws -> [AVMetadataItem] {
        let mirrors: [(AVMetadataKey, AVMetadataIdentifier)] = [
            (.commonKeyMake, .quickTimeMetadataMake),
            (.commonKeyModel, .quickTimeMetadataModel),
            (.commonKeySoftware, .quickTimeMetadataSoftware),
            (.commonKeyCreationDate, .quickTimeMetadataCreationDate),
            (.commonKeyLocation, .quickTimeMetadataLocationISO6709),
        ]
        let existingKeys = Set(existing.filter { $0.keySpace == .quickTimeMetadata }.compactMap(\.identifier))
        let common = try await asset.load(.commonMetadata)

        var mirrored: [AVMetadataItem] = []
        for (commonKey, identifier) in mirrors where !existingKeys.contains(identifier) {
            guard let item = common.first(where: { $0.commonKey == commonKey && $0.keySpace != .quickTimeMetadata }),
                  let value = try await item.load(.stringValue), !value.isEmpty
            else { continue }
            let key = AVMutableMetadataItem()
            key.identifier = identifier
            key.value = value as NSString
            key.dataType = kCMMetadataBaseDataType_UTF8 as String
            mirrored.append(key)
        }
        return mirrored
    }
}
