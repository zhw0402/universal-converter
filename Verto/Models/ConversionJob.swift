//
//  ConversionJob.swift
//  Verto
//
//  One file in the queue — including its own per-file quality options
//  and a live estimate of the output size.
//

import Foundation
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

@MainActor
final class ConversionJob: ObservableObject, Identifiable {

    enum Status: Equatable {
        case waiting
        case converting(Double)          // 0...1
        case completed([URL])            // one or more output files (PDF pages…)
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .completed, .failed: return true
            default:                  return false
            }
        }
    }

    nonisolated let id = UUID()
    nonisolated let sourceURL: URL
    nonisolated let sourceType: UTType
    nonisolated let fileSize: Int64
    nonisolated let availableFormats: [OutputFormat]

    @Published var outputFormat: OutputFormat
    @Published var status: Status = .waiting
    @Published var thumbnail: PlatformImage?
    @Published var durationSeconds: Double?   // videos & audio, loaded async

    // Per-file options (seeded from the global defaults, tunable per row)
    @Published var imageQuality: Double
    @Published var imageResize: ImageResize
    @Published var videoResolution: VideoResolution
    @Published var videoCodec: VideoCodec
    @Published var videoSizing: VideoSizing = .auto
    @Published var audioKbps: Int
    @Published var pdfQuality: PDFQuality

    // Per-file edits (default = leave the file alone)
    @Published var rotation: RotationAngle = .none    // images & PDF
    @Published var pageRange: String = ""             // PDF ("" = all pages)
    @Published var trimMargins: Bool = false          // PDF
    @Published var audioSpeed: Double = 1.0           // audio output, pitch kept
    @Published var gainDB: Double = 0                 // audio output
    @Published var fadeInSeconds: Double = 0          // audio output
    @Published var fadeOutSeconds: Double = 0         // audio output
    @Published var trimStartText: String = ""         // audio & video ("1:30")
    @Published var trimEndText: String = ""

    init?(url: URL, defaults: JobDefaults) {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let type = values?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
            ?? .data

        let formats = OutputFormat.compatibleFormats(for: type)
        guard let defaultFormat = OutputFormat.defaultFormat(for: type), !formats.isEmpty else {
            return nil // unsupported file type
        }

        self.sourceURL = url
        self.sourceType = type
        self.fileSize = Int64(values?.fileSize ?? 0)
        self.availableFormats = formats
        self.outputFormat = defaultFormat
        self.imageQuality = defaults.imageQuality
        self.imageResize = defaults.imageResize
        self.videoResolution = defaults.videoResolution
        self.videoCodec = defaults.videoCodec
        self.audioKbps = defaults.audioKbps
        self.pdfQuality = defaults.pdfQuality
    }

    var fileName: String { sourceURL.lastPathComponent }

    var isPDFSource: Bool { sourceType.conforms(to: .pdf) }
    var isImageSource: Bool { !isPDFSource && sourceType.conforms(to: .image) }
    var isAVSource: Bool {
        sourceType.conforms(to: .movie) || sourceType.conforms(to: .video)
            || sourceType.conforms(to: .audio)
    }

    // MARK: - Trim / edits

    var trimStartSeconds: Double? { parseTimecode(trimStartText) }
    var trimEndSeconds: Double? { parseTimecode(trimEndText) }

    /// Duration after trim (and, for audio output, speed) — drives the estimate.
    var editedDurationSeconds: Double? {
        guard let full = durationSeconds else { return nil }
        let start = min(trimStartSeconds ?? 0, full)
        let end = min(trimEndSeconds ?? full, full)
        var duration = max(0, end - start)
        if outputFormat.category == .audio, audioSpeed > 0 {
            duration /= audioSpeed
        }
        return duration
    }

    /// Compact badges shown on the row when edits are active: "↻90° ✂1:30 1.5×"
    var editBadges: [String] {
        var badges: [String] = []
        if rotation != .none { badges.append("↻\(rotation.rawValue)°") }
        if isPDFSource {
            let range = pageRange.trimmingCharacters(in: .whitespaces)
            if !range.isEmpty, range.lowercased() != "all",
               range.contains(where: \.isNumber) {   // only when it can actually filter
                badges.append("第 \(range)")
            }
            if trimMargins { badges.append("⌗裁边") }
        }
        if trimStartSeconds != nil || trimEndSeconds != nil {
            let start = trimStartSeconds.map(formatTimecode) ?? "0:00"
            let end = trimEndSeconds.map(formatTimecode) ?? "结束"
            badges.append("✂\(start)–\(end)")
        }
        if outputFormat.category == .audio {
            if audioSpeed != 1.0 {
                badges.append(String(format: "%g×", audioSpeed))
            }
            if gainDB != 0 {
                badges.append(String(format: "%+g dB", gainDB))
            }
            if fadeInSeconds > 0 || fadeOutSeconds > 0 { badges.append("淡入淡出") }
        }
        return badges
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// "JPEG → PNG" style summary of what this job did.
    var summary: String {
        let src = sourceURL.pathExtension.uppercased()
        return outputFormat.isSameFormat(as: sourceType)
            ? "压缩 \(src)"
            : "\(src) → \(outputFormat.displayName)"
    }

    // MARK: - Size estimate (Movavi-style)

    /// Predicted output size, when it can be known before encoding.
    /// Uses the trimmed (and speed-adjusted) duration.
    var estimatedOutputBytes: Int64? {
        switch outputFormat.category {
        case .audio:
            guard let duration = editedDurationSeconds else { return nil }
            switch outputFormat {
            case .m4a:
                return Int64(Double(audioKbps) * 1_000 / 8 * duration)
            case .wav, .aiff, .caf:
                return Int64(176_400 * duration)   // 44.1 kHz · stereo · 16-bit
            default:
                return nil
            }
        case .video:
            guard let duration = editedDurationSeconds else { return nil }
            let audioBits = Double(audioKbps) * 1_000
            switch videoSizing {
            case .targetSize(let megabytes):
                return Int64(megabytes * 1_000_000)
            case .bitrate(let mbps):
                return Int64((mbps * 1_000_000 + audioBits) / 8 * duration)
            case .auto:
                guard let videoBits = videoResolution.estimatedBitsPerSecond else { return nil }
                return Int64((videoBits + audioBits) / 8 * duration)
            }
        default:
            return nil
        }
    }

    var formattedEstimate: String? {
        guard case .waiting = status, let bytes = estimatedOutputBytes else { return nil }
        return "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
