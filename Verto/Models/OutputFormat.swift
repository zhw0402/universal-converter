//
//  OutputFormat.swift
//  万能转换
//
//  Every format the app can write, plus the logic that decides which
//  targets are offered for a given source file.
//

import Foundation
import UniformTypeIdentifiers

enum MediaCategory: String {
    case image, video, audio, document
}

enum OutputFormat: String, CaseIterable, Identifiable, Codable {
    // Images
    case jpeg, png, heic, tiff, bmp, gif
    // Documents
    case pdf
    // Video containers
    case mp4, mov, m4v
    // Audio
    case m4a, wav, aiff, caf
    // Text documents
    case md, txt, html, docx, epub
    // Structured data
    case json, csv, xml, plist

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png:  return "PNG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .bmp:  return "BMP"
        case .gif:  return "GIF"
        case .pdf:  return "PDF"
        case .mp4:  return "MP4"
        case .mov:  return "MOV"
        case .m4v:  return "M4V"
        case .m4a:  return "M4A (AAC)"
        case .wav:  return "WAV"
        case .aiff: return "AIFF"
        case .caf:  return "CAF"
        case .md:   return "Markdown"
        case .txt:  return "纯文本"
        case .html: return "HTML"
        case .docx: return "Word"
        case .epub: return "EPUB"
        case .json: return "JSON"
        case .csv:  return "CSV"
        case .xml:  return "XML"
        case .plist: return "plist"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        default:    return rawValue
        }
    }

    var category: MediaCategory {
        switch self {
        case .jpeg, .png, .heic, .tiff, .bmp, .gif: return .image
        case .pdf:                                  return .document
        case .md, .txt, .html, .docx, .epub:        return .document
        case .json, .csv, .xml, .plist:             return .document
        case .mp4, .mov, .m4v:                      return .video
        case .m4a, .wav, .aiff, .caf:               return .audio
        }
    }

    /// Text-shaped outputs bypass the media option panels entirely.
    var isTextLike: Bool {
        switch self {
        case .md, .txt, .html, .docx, .epub, .json, .csv, .xml, .plist: return true
        default: return false
        }
    }

    /// UTType used by ImageIO when encoding still images.
    var imageUTType: UTType? {
        switch self {
        case .jpeg: return .jpeg
        case .png:  return .png
        case .heic: return .heic
        case .tiff: return .tiff
        case .bmp:  return .bmp
        case .gif:  return .gif
        default:    return nil
        }
    }

    /// The UTType a *source* file must conform to for this format to be
    /// considered "保持原格式" (used to label the compress option).
    var matchingUTType: UTType? {
        switch self {
        case .jpeg: return .jpeg
        case .png:  return .png
        case .heic: return .heic
        case .tiff: return .tiff
        case .bmp:  return .bmp
        case .gif:  return .gif
        case .pdf:  return .pdf
        case .mp4:  return .mpeg4Movie
        case .mov:  return .quickTimeMovie
        case .m4v:  return UTType("com.apple.m4v-video")
        case .m4a:  return .mpeg4Audio
        case .wav:  return .wav
        case .aiff: return .aiff
        case .caf:  return UTType("com.apple.coreaudio-format")
        default:    return nil
        }
    }

    // MARK: - Compatibility

    /// Output formats offered for a given source type.
    static func compatibleFormats(for sourceType: UTType) -> [OutputFormat] {
        if sourceType.conforms(to: .pdf) {
            return [.jpeg, .png, .tiff, .pdf]
        }
        if sourceType.conforms(to: .image) {
            return [.jpeg, .png, .heic, .tiff, .bmp, .gif, .pdf]
        }
        if sourceType.conforms(to: .movie) || sourceType.conforms(to: .video) {
            return [.mp4, .mov, .m4v, .m4a, .wav, .aiff, .caf]
        }
        if sourceType.conforms(to: .audio) {
            return [.m4a, .wav, .aiff, .caf]
        }

        if let kind = DocumentProcessor.kind(for: sourceType) {
            let excluded: OutputFormat?
            switch kind {
            case .plainText: excluded = .txt
            case .markdown:  excluded = .md
            case .html:      excluded = .html
            case .docx:      excluded = .docx
            case .epub:      excluded = .epub
            case .rtf:       excluded = nil
            }
            return DocumentProcessor.outputFormats.filter { $0 != excluded }
        }

        if let kind = DataProcessor.kind(for: sourceType) {
            let excluded: OutputFormat
            switch kind {
            case .json:  excluded = .json
            case .csv:   excluded = .csv
            case .xml:   excluded = .xml
            case .plist: excluded = .plist
            }
            return DataProcessor.outputFormats.filter { $0 != excluded }
        }

        return []
    }

    /// True when converting `sourceType` to `self` keeps the same container,
    /// i.e. the operation is a re-encode / compression rather than a conversion.
    func isSameFormat(as sourceType: UTType) -> Bool {
        guard let match = matchingUTType else { return false }
        return sourceType.conforms(to: match)
    }

    /// A sensible default target for a given source type.
    static func defaultFormat(for sourceType: UTType) -> OutputFormat? {
        let options = compatibleFormats(for: sourceType)
        guard !options.isEmpty else { return nil }

        if sourceType.conforms(to: .pdf) { return .jpeg }
        if sourceType.conforms(to: .image) {
            return sourceType.conforms(to: .jpeg) ? .png : .jpeg
        }
        if sourceType.conforms(to: .movie) || sourceType.conforms(to: .video) {
            return sourceType.conforms(to: .mpeg4Movie) ? .mov : .mp4
        }
        if sourceType.conforms(to: .audio) {
            return sourceType.conforms(to: .mpeg4Audio) ? .wav : .m4a
        }

        if let kind = DocumentProcessor.kind(for: sourceType) {
            let preferred: OutputFormat
            switch kind {
            case .markdown:  preferred = .html
            case .html:      preferred = .md
            case .docx:      preferred = .md
            case .epub:      preferred = .md
            case .rtf:       preferred = .md
            case .plainText: preferred = .md
            }
            return options.contains(preferred) ? preferred : options.first
        }

        if let kind = DataProcessor.kind(for: sourceType) {
            let preferred: OutputFormat
            switch kind {
            case .json:  preferred = .csv
            case .csv:   preferred = .json
            case .xml:   preferred = .json
            case .plist: preferred = .json
            }
            return options.contains(preferred) ? preferred : options.first
        }

        return options.first
    }
}
