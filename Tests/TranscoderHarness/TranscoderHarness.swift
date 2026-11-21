//
//  TranscoderHarness.swift
//  TranscoderHarness
//
//  Runs the apps' shared "Size + Speed" encoder (Shared/VideoTranscoder.swift)
//  from the command line, for CI and for benchmarking on a real Mac. Build it
//  with Tests/run_transcoder.sh (or the commands in .github/workflows/encode-tests.yml).
//
//  transcoder-harness <source> <output> [options]
//    --scale <f>         1, 0.5 or 0.25 (default 1)
//    --no-fps-cap        keep every frame (default: cap at 24 fps)
//    --keyframes <k>     seconds between keyframes (default 10), "single"
//                        (only the first frame) or "auto" (the encoder's choice)
//    --quality <q>       constant quality 0…1 (default 0)
//    --no-quality        don't ask for constant quality
//    --no-bitrate        don't ask for the lowest bitrate
//    --no-power-saving   don't ask for MaximizePowerEfficiency
//    --prioritize-speed  ask for PrioritizeEncodingSpeedOverQuality (default)
//    --no-prioritize-speed  don't
//    --min-qp <n>        lowest quantizer allowed (MinAllowedFrameQP; 0 = not set)
//    --adaptive-qp       leave SpatialAdaptiveQPLevel on (default: off)
//    --copy-metadata     then copy the source's metadata with MetadataCopier
//                        (what the iOS app does)
//    --encoders          only list the HEVC encoders VideoToolbox has
//

import AVFoundation
import Foundation
import VideoToolbox

@main
struct TranscoderHarness {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--encoders") {
            listEncoders()
            return
        }
        guard args.count >= 2 else {
            print("usage: transcoder-harness <source> <output> [--scale f] [--no-fps-cap] [--keyframes s|single|auto] "
                + "[--quality q] [--no-power-saving] [--prioritize-speed] [--min-qp n] [--adaptive-qp] [--no-quality] [--no-bitrate] [--copy-metadata]")
            exit(2)
        }
        let source = URL(fileURLWithPath: args.removeFirst())
        let output = URL(fileURLWithPath: args.removeFirst())

        var settings = VideoTranscoder.Settings.sizeAndSpeed(scale: 1)
        var copyMetadata = false
        while !args.isEmpty {
            let option = args.removeFirst()
            switch option {
            case "--scale": settings.scale = Double(args.removeFirst()) ?? 1
            case "--no-fps-cap": settings.maxFrameRate = nil
            case "--keyframes":
                let value = args.removeFirst()
                switch value {
                case "single": settings.keyFrames = .single
                case "auto": settings.keyFrames = .encoderChoice
                default: settings.keyFrames = .every(Double(value) ?? 10)
                }
            case "--quality": settings.quality = Double(args.removeFirst())
            case "--no-quality": settings.quality = nil
            case "--no-bitrate": settings.bitrate = nil
            case "--no-power-saving": settings.powerEfficient = false
            case "--prioritize-speed": settings.prioritizeSpeed = true
            case "--no-prioritize-speed": settings.prioritizeSpeed = false
            case "--min-qp": settings.minFrameQP = Int(args.removeFirst()).flatMap { $0 > 0 ? $0 : nil }
            case "--adaptive-qp": settings.adaptiveQP = true
            case "--copy-metadata": copyMetadata = true
            default:
                print("Unknown option \(option)")
                exit(2)
            }
        }

        listEncoders()
        let start = Date()
        do {
            try await VideoTranscoder.transcode(
                source: source,
                destination: output,
                settings: settings,
                log: { print($0) },
                progress: { _ in }
            )
        } catch {
            print("FAILED: \(error.localizedDescription)")
            exit(1)
        }
        let seconds = Date().timeIntervalSince(start)

        if copyMetadata {
            do {
                let notes = try MetadataCopier.copy(from: source, to: output)
                print("Metadata: " + notes.joined(separator: ", "))
            } catch {
                print("FAILED: metadata copy: \(error.localizedDescription)")
                exit(1)
            }
        }

        let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print(String(format: "Done in %.1f s: %@ → %@ bytes", seconds, "\(sourceSize)", "\(size)"))
        print(String(format: "SECONDS=%.2f", seconds))
    }

    /// Which HEVC encoders VideoToolbox offers, and whether they are hardware.
    static func listEncoders() {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]] else {
            print("VideoToolbox: can't list encoders")
            return
        }
        for encoder in encoders {
            guard let codec = encoder[kVTVideoEncoderList_CodecType as String] as? UInt32,
                  codec == kCMVideoCodecType_HEVC else { continue }
            let name = encoder[kVTVideoEncoderList_EncoderName as String] as? String ?? "?"
            let hardware = (encoder[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) ?? false
            print("VideoToolbox HEVC encoder: \(name) (\(hardware ? "hardware" : "software"))")
        }
    }
}
