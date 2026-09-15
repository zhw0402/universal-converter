//
//  ConversionSettings.swift
//  Verto
//
//  User-tunable options. Video and audio can be sized three ways,
//  Movavi-style: automatic, explicit bitrate, or a target file size.
//

import Foundation
import AVFoundation

// MARK: - Video

enum VideoCodec: String, CaseIterable, Identifiable, Sendable {
    case h264 = "H.264（兼容性最好）"
    case hevc = "HEVC（体积小约 40%）"

    var id: String { rawValue }

    var avCodecType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}

enum VideoResolution: String, CaseIterable, Identifiable, Sendable {
    case original = "原始"
    case r1080    = "1080p"
    case r720     = "720p"
    case r540     = "540p"

    var id: String { rawValue }

    var maxDimension: CGFloat? {
        switch self {
        case .original: return nil
        case .r1080:    return 1920
        case .r720:     return 1280
        case .r540:     return 960
        }
    }

    /// Preset used when sizing is .auto (Apple's encoder picks the bitrate).
    var avPresetName: String {
        switch self {
        case .original: return AVAssetExportPresetHighestQuality
        case .r1080:    return AVAssetExportPreset1920x1080
        case .r720:     return AVAssetExportPreset1280x720
        case .r540:     return AVAssetExportPreset960x540
        }
    }

    /// Rough bitrate used only for the size estimate shown in the UI.
    var estimatedBitsPerSecond: Double? {
        switch self {
        case .original: return nil
        case .r1080:    return 8_000_000
        case .r720:     return 5_000_000
        case .r540:     return 2_500_000
        }
    }
}

/// How the output size of a video is decided.
enum VideoSizing: Equatable, Hashable, Sendable {
    case auto                    // encoder decides (quality presets)
    case bitrate(Double)         // megabits per second
    case targetSize(Double)      // megabytes for the whole file
}

// MARK: - Images & PDF

enum ImageResize: String, CaseIterable, Identifiable, Sendable {
    case original = "原始尺寸"
    case r4096    = "最长边 4096 px"
    case r2048    = "最长边 2048 px"
    case r1024    = "最长边 1024 px"

    var id: String { rawValue }

    var maxPixelSize: CGFloat? {
        switch self {
        case .original: return nil
        case .r4096:    return 4096
        case .r2048:    return 2048
        case .r1024:    return 1024
        }
    }
}

enum PDFQuality: String, CaseIterable, Identifiable, Sendable {
    case dpi100 = "100 DPI（最小）"
    case dpi150 = "150 DPI（均衡）"
    case dpi200 = "200 DPI"
    case dpi300 = "300 DPI（印刷）"

    var id: String { rawValue }

    var dpi: CGFloat {
        switch self {
        case .dpi100: return 100
        case .dpi150: return 150
        case .dpi200: return 200
        case .dpi300: return 300
        }
    }
}

// MARK: - Rotation (images & PDF pages)

enum RotationAngle: Int, CaseIterable, Identifiable, Sendable {
    case none = 0
    case r90  = 90
    case r180 = 180
    case r270 = 270

    var id: Int { rawValue }

    var label: String {
        self == .none ? "无" : "\(rawValue)°"
    }
}

// MARK: - Audio

/// AAC bitrates offered for M4A output (kbps).
let audioBitrateChoices = [64, 96, 128, 192, 256, 320]

/// Playback-speed presets offered for audio output (pitch is preserved).
let audioSpeedChoices: [Double] = [0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

// MARK: - Timecode parsing

/// "90", "1:30" or "1:30.5" → seconds. Empty / invalid / non-finite → nil.
/// Capped below 100 hours so downstream Int conversions can never trap.
func parseTimecode(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let parts = trimmed.split(separator: ":").map(String.init)
    guard parts.count <= 3, !parts.isEmpty else { return nil }
    var seconds = 0.0
    for part in parts {
        guard let value = Double(part.replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value >= 0 else { return nil }
        seconds = seconds * 60 + value
    }
    guard seconds.isFinite else { return nil }
    return min(seconds, 359_999)
}

/// Seconds → "m:ss" (or "h:mm:ss" past the hour) for placeholders and badges.
func formatTimecode(_ seconds: Double) -> String {
    let total = Int(min(max(0, seconds), 359_999).rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%d:%02d", minutes, secs)
}

// MARK: - Snapshots

/// Defaults applied to every newly added file (each job can then be tuned individually).
struct JobDefaults {
    var imageQuality: Double
    var imageResize: ImageResize
    var videoResolution: VideoResolution
    var videoCodec: VideoCodec
    var audioKbps: Int
    var pdfQuality: PDFQuality
}

/// Immutable per-job snapshot handed to the engine when a batch starts.
struct ConversionSettings: Sendable {
    var imageQuality: Double = 0.85
    var maxPixelSize: CGFloat? = nil
    var pdfDPI: CGFloat = 150
    var videoCodec: VideoCodec = .h264
    var videoResolution: VideoResolution = .original
    var videoSizing: VideoSizing = .auto
    var audioKbps: Int = 128

    // Edits (all default to "保持原样")
    var rotation: RotationAngle = .none      // images & PDF pages
    var pageRange: String = ""               // PDF: "" = all, else "1-3,7"
    var trimMargins: Bool = false            // PDF: auto-crop white margins
    var audioSpeed: Double = 1.0             // audio output: 0.5×–2×, pitch kept
    var gainDB: Double = 0                   // audio output: −12…+12 dB
    var fadeInSeconds: Double = 0            // audio output
    var fadeOutSeconds: Double = 0           // audio output
    var trimStart: Double? = nil             // audio & video, seconds
    var trimEnd: Double? = nil               // audio & video, seconds

    var wantsAudioEffects: Bool {
        audioSpeed != 1.0 || gainDB != 0 || fadeInSeconds > 0 || fadeOutSeconds > 0
    }

    var trimRangeSeconds: (start: Double, end: Double?)? {
        if trimStart == nil && trimEnd == nil { return nil }
        return (trimStart ?? 0, trimEnd)
    }
}

/// Parse a page-range string like "1-3, 7, 12-14" against a page count.
/// Empty or unparsable input → all pages. Out-of-range entries are clamped/dropped.
func parsePageRange(_ text: String, pageCount: Int) -> [Int] {
    let all = Array(1...max(1, pageCount))
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty, trimmed != "all" else { return all }

    var pages: [Int] = []
    for token in trimmed.split(separator: ",") {
        let piece = token.trimmingCharacters(in: .whitespaces)
        if let dash = piece.firstIndex(where: { $0 == "-" || $0 == "–" }) {
            let lowText = piece[..<dash].trimmingCharacters(in: .whitespaces)
            let highText = piece[piece.index(after: dash)...].trimmingCharacters(in: .whitespaces)
            guard let low = Int(lowText) else { continue }
            let high = Int(highText) ?? pageCount        // "5-" = 5 to end
            let clampedLow = max(1, low)
            let clampedHigh = min(pageCount, max(1, high))
            guard clampedLow <= clampedHigh else { continue }   // fully out of range → skip
            pages.append(contentsOf: clampedLow...clampedHigh)
        } else if let single = Int(piece), (1...pageCount).contains(single) {
            pages.append(single)
        }
    }
    let unique = Array(Set(pages)).sorted()
    return unique.isEmpty ? all : unique
}
