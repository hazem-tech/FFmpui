//
//  OutputScale.swift
//  shrk
//
//  The "Scale" menu: output width and height as a fraction of the original's.
//  Works the same with every mode. Shared by both apps.
//

import Foundation

nonisolated enum OutputScale: Double, CaseIterable, Identifiable, Sendable {
    case full = 1
    case half = 0.5
    case quarter = 0.25

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .full: "1×"
        case .half: "0.5×"
        case .quarter: "0.25×"
        }
    }

    /// Value for compress_video.sh's `--scale`.
    var argument: String {
        switch self {
        case .full: "1"
        case .half: "0.5"
        case .quarter: "0.25"
        }
    }
}
