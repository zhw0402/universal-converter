//
//  ConversionEngine.swift
//  Verto
//
//  Routes a job to the right processor. All heavy lifting happens off
//  the main thread; progress is reported through a Sendable callback.
//

import Foundation
import UniformTypeIdentifiers

enum ConversionError: LocalizedError {
    case unsupportedConversion
    case cannotOpenSource
    case encodingFailed(String)
    case noAudioTrack
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedConversion:
            return "不支持这种格式转换。"
        case .cannotOpenSource:
            return "无法打开该文件。"
        case .encodingFailed(let detail):
            return "编码失败：\(detail)"
        case .noAudioTrack:
            return "该文件不含音轨。"
        case .exportFailed(let detail):
            return "导出失败：\(detail)"
        }
    }
}

struct ConversionEngine {

    /// Convert a single file. Returns the URLs that were written.
    static func convert(source: URL,
                        sourceType: UTType,
                        to format: OutputFormat,
                        settings: ConversionSettings,
                        outputDirectory: URL,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {

        // PDFs first — UTType.pdf does not conform to .image, but be explicit.
        if sourceType.conforms(to: .pdf) {
            let urls: [URL]
            if format == .pdf {
                urls = try PDFProcessor.compress(source: source,
                                                 settings: settings,
                                                 outputDirectory: outputDirectory,
                                                 progress: progress)
            } else {
                urls = try PDFProcessor.toImages(source: source,
                                                 format: format,
                                                 settings: settings,
                                                 outputDirectory: outputDirectory,
                                                 progress: progress)
            }
            progress(1)
            return urls
        }

        if sourceType.conforms(to: .image) {
            let urls: [URL]
            if format == .pdf {
                urls = try ImageProcessor.imageToPDF(source: source,
                                                     settings: settings,
                                                     outputDirectory: outputDirectory)
            } else {
                urls = try ImageProcessor.convert(source: source,
                                                  to: format,
                                                  settings: settings,
                                                  outputDirectory: outputDirectory)
            }
            progress(1)
            return urls
        }

        if sourceType.conforms(to: .movie) || sourceType.conforms(to: .video) || sourceType.conforms(to: .audio) {
            return try await AVProcessor.convert(source: source,
                                                 to: format,
                                                 settings: settings,
                                                 outputDirectory: outputDirectory,
                                                 progress: progress)
        }

        if let kind = DocumentProcessor.kind(for: sourceType) {
            let url = try DocumentProcessor.convert(source: source,
                                                    kind: kind,
                                                    to: format,
                                                    outputDirectory: outputDirectory)
            progress(1)
            return [url]
        }

        if let kind = DataProcessor.kind(for: sourceType) {
            let url = try DataProcessor.convert(source: source,
                                                kind: kind,
                                                to: format,
                                                outputDirectory: outputDirectory)
            progress(1)
            return [url]
        }

        throw ConversionError.unsupportedConversion
    }

    /// "photo.jpg" already exists → "photo 2.jpg", "photo 3.jpg", …
    static func uniqueDestination(in directory: URL, baseName: String, fileExtension: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(counter)").appendingPathExtension(fileExtension)
            counter += 1
        }
        return candidate
    }
}

/// Lets AVFoundation session/reader/writer objects cross `@Sendable`
/// closure boundaries. Safe here because every wrapped object is only
/// touched from one serial context at a time (poller, serial queue,
/// or cancellation handler calling a thread-safe cancel method).
struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
