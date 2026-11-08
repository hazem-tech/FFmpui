//
//  VideoTranscoder.swift
//  FFmpui
//
//  Re-encodes a video to HEVC with AVFoundation (Apple's VideoToolbox
//  hardware encoder, the same one ffmpeg's hevc_videotoolbox uses).
//  It mirrors the ffmpeg step of compress_video.sh:
//
//    • first video track → HEVC, rotation flag kept (pixels not rotated)
//    • every audio track copied untouched
//    • timecode / metadata / telemetry / subtitle tracks copied when the
//      container accepts them, otherwise a second try with video + audio only
//
//  Camera / lens / GPS tags and file dates are added afterwards by the
//  script's ExifTool step (`compress_video.sh --encoded`), exactly as for
//  the ffmpeg encoder. No AppKit/UIKit here, so iOS can reuse this file.
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
        bitrate: Int,
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
                             bitrate: bitrate, includeOtherTracks: hasOtherTracks, progress: progress)
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
                                 bitrate: bitrate, includeOtherTracks: false, progress: progress)
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
    }

    private static func encode(
        asset: AVURLAsset,
        tracks: [AVAssetTrack],
        videoTrack: AVAssetTrack,
        destination: URL,
        bitrate: Int,
        includeOtherTracks: Bool,
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
        let video = try await videoPair(for: videoTrack, writer: writer, bitrate: bitrate)
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
                    if pair.isVideo, duration > 0 {
                        let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        let value = min(max(seconds / duration, 0), 1)
                        if value - lastReported >= 0.002 {
                            lastReported = value
                            progress(value)
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

    private static func videoPair(for track: AVAssetTrack, writer: AVAssetWriter, bitrate: Int) async throws -> Pair {
        let (formats, naturalSize, transform, timeScale, frameRate) = try await track.load(
            .formatDescriptions, .naturalSize, .preferredTransform, .naturalTimeScale, .nominalFrameRate)
        let extensions = formats.first.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] } ?? [:]

        // Keep 10-bit / HDR (HLG, PQ) sources 10-bit.
        let bits = (extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber)?.intValue ?? 8
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let hdrTransfers = [kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
                            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String]
        let tenBit = bits > 8 || hdrTransfers.contains(transfer ?? "")

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: tenBit
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.alwaysCopiesSampleData = false

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoProfileLevelKey: tenBit
                ? kVTProfileLevel_HEVC_Main10_AutoLevel as String
                : kVTProfileLevel_HEVC_Main_AutoLevel as String,
        ]
        if frameRate > 0 {
            compression[AVVideoExpectedSourceFrameRateKey] = frameRate
        }

        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(naturalSize.width.rounded()),
            AVVideoHeightKey: Int(naturalSize.height.rounded()),
            AVVideoCompressionPropertiesKey: compression,
        ]
        if let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
           let transfer,
           let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: primaries,
                AVVideoTransferFunctionKey: transfer,
                AVVideoYCbCrMatrixKey: matrix,
            ]
            if !writer.canApply(outputSettings: settings, forMediaType: .video) {
                settings[AVVideoColorPropertiesKey] = nil
            }
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw Failure.unsupportedSettings
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = transform  // rotation flag, like ffmpeg's -noautorotate + copied display matrix
        if timeScale > 0 { input.mediaTimeScale = timeScale }
        try await copyTrackProperties(from: track, to: input)

        return Pair(output: output, input: input, isVideo: true)
    }

    private static func copyTrackProperties(from track: AVAssetTrack, to input: AVAssetWriterInput) async throws {
        let (language, extendedLanguage) = try await track.load(.languageCode, .extendedLanguageTag)
        if let language { input.languageCode = language }
        if let extendedLanguage { input.extendedLanguageTag = extendedLanguage }
    }

    /// Movie-level tags the container can hold. ExifTool copies everything
    /// afterwards anyway; this is just a baseline.
    private static func containerMetadata(of asset: AVURLAsset, for fileType: AVFileType) async throws -> [AVMetadataItem] {
        let keySpaces: Set<AVMetadataKeySpace> = fileType == .mov
            ? [.quickTimeMetadata, .quickTimeUserData]
            : [.iTunes, .isoUserData]
        return try await asset.load(.metadata).filter { item in
            item.keySpace.map(keySpaces.contains) ?? false
        }
    }
}
