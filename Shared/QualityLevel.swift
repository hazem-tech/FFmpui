//
//  QualityLevel.swift
//  shrk
//
//  The "Quality" menu of the quality modes: how close to the original the
//  compressed video should look, as a VMAF score (0–100, how alike two
//  videos look). Size + Quality (Mac, x265) searches each video for the
//  smallest file that reaches the score; Speed + Quality (both apps,
//  hardware encoder) uses a fixed encoder setting that reaches about that
//  score on the test clips. Shared by both apps.
//

import Foundation

nonisolated enum QualityLevel: String, CaseIterable, Identifiable, Sendable {
    case high
    case medium
    case low

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    /// Target VMAF score.
    var vmaf: Int {
        switch self {
        case .high: 97
        case .medium: 95
        case .low: 92
        }
    }

    var caption: String {
        switch self {
        case .high: "Hard to tell apart from the original, even side by side."
        case .medium: "Differences are hard to notice in normal viewing."
        case .low: "Slightly softer if you look for it, and smaller."
        }
    }

    /// Speed + Quality: the hardware encoder's constant-quality setting (0…1)
    /// that reaches `vmaf` on the test clips (Tests/tune_speed_quality.sh).
    /// Needed per clip for 97 / 95 / 92: iPhone 0.600 / 0.570 / 0.527,
    /// 23.976 fps 0.597 / 0.568 / 0.525, Samsung 0.731 / 0.677 / 0.611, HDR
    /// 0.844 / 0.665 / 0.576. One setting has to fit every video, so the
    /// hardest clip decides, except for High on HDR: VMAF levels off around
    /// 97 there (it isn't made for HDR), and following it would make every
    /// other video 3–5× bigger; 0.74 gives HDR about 96.3.
    var encoderQuality: Double {
        switch self {
        case .high: 0.74
        case .medium: 0.68
        case .low: 0.62
        }
    }

    /// Speed + Quality on a Mac whose encoder has no constant-quality mode
    /// (Intel): bits per pixel per frame to aim for instead.
    var fallbackBitsPerPixel: Double {
        switch self {
        case .high: 0.12
        case .medium: 0.08
        case .low: 0.05
        }
    }
}
