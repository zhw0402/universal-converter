//
//  DocumentProcessor.swift
//  万能转换
//
//  Reads Word (.docx), EPUB, RTF, Markdown, HTML and plain-text files
//  into the Markdown pivot. Everything stays on device.
//

import Foundation
import CoreFoundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Source kinds

enum TextDocumentKind: String {
    case plainText
    case markdown
    case html
    case rtf
    case docx
    case epub

    var displayName: String {
        switch self {
        case .plainText: return "TXT"
        case .markdown:  return "MD"
        case .html:      return "HTML"
        case .rtf:       return "RTF"
        case .docx:      return "DOCX"
        case .epub:      return "EPUB"
        }
    }

    /// Match on the concrete type identifier rather than `conforms(to:)`,
    /// because the text types overlap heavily (CSV and Markdown both
    /// claim conformance to plain text).
    static func detected(from type: UTType) -> TextDocumentKind? {
        switch type.identifier {
        case "org.openxmlformats.wordprocessingml.document",
             "org.openxmlformats.wordprocessingml.document.macroenabled",
             "com.microsoft.word.doc":
            return .docx
        case "org.idpf.epub-container":
            return .epub
        case "net.daringfireball.markdown", "public.markdown":
            return .markdown
        case "public.html", "public.xhtml":
            return .html
        case "public.rtf":
            return .rtf
        case "public.plain-text", "public.utf8-plain-text", "public.text":
            return .plainText
        default:
            break
        }

        // Fall back to the file extension for types the system reports generically.
        let lowered = type.preferredFilenameExtension?.lowercased() ?? ""
        switch lowered {
        case "docx", "doc":  return .docx
        case "epub":         return .epub
        case "md", "markdown": return .markdown
        case "html", "htm", "xhtml": return .html
        case "rtf":          return .rtf
        case "txt", "text":  return .plainText
        default:             return nil
        }
    }
}

// MARK: - Processor

enum DocumentProcessor {

    static let outputFormats: [OutputFormat] = [.md, .txt, .html, .docx, .epub]

    static func kind(for sourceType: UTType) -> TextDocumentKind? {
        TextDocumentKind.detected(from: sourceType)
    }

    static func markdown(from url: URL, kind: TextDocumentKind) throws -> String {
        let data = try Data(contentsOf: url)
        return try markdown(from: data, kind: kind, baseName: url.deletingPathExtension().lastPathComponent)
    }

    static func markdown(from data: Data, kind: TextDocumentKind, baseName: String) throws -> String {
        switch kind {
        case .docx:
            return try DocxReader.markdown(from: data)
        case .epub:
            return try EpubReader.markdown(from: data)
        case .rtf:
            return try richTextMarkdown(from: data)
        case .html:
            let html = decodeText(data)
            return Markup.markdown(fromHTML: html)
        case .markdown:
            return decodeText(data)
        case .plainText:
            return Markup.markdown(fromPlainText: decodeText(data))
        }
    }

    static func convert(source: URL,
                        kind: TextDocumentKind,
                        to format: OutputFormat,
                        outputDirectory: URL) throws -> URL {
        let markdown = try markdown(from: source, kind: kind)

        let baseName = source.deletingPathExtension().lastPathComponent
        let destination = ConversionEngine.uniqueDestination(in: outputDirectory,
                                                             baseName: baseName,
                                                             fileExtension: format.fileExtension)

        switch format {
        case .md:
            try write(markdown, to: destination)
        case .txt:
            try write(Markup.plainText(fromMarkdown: markdown), to: destination)
        case .html:
            try write(DocumentWriter.htmlDocument(markdown: markdown, title: baseName), to: destination)
        case .docx:
            try DocumentWriter.docxData(markdown: markdown).write(to: destination)
        case .epub:
            try DocumentWriter.epubData(markdown: markdown,
                                        title: Markup.title(fromMarkdown: markdown, fallback: baseName))
                 .write(to: destination)
        default:
            throw ConversionError.unsupportedConversion
        }
        return destination
    }

    // MARK: - Helpers

    /// Text files in the wild are not always UTF-8 — try the usual
    /// suspects before giving up. GB18030 covers the Chinese legacy
    /// encodings as well, since GBK and GB2312 are subsets of it.
    static func decodeText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        let candidates: [String.Encoding] = [.utf16, .utf16LittleEndian, .utf16BigEndian,
                                             .isoLatin1, .windowsCP1252, gb18030]
        for encoding in candidates {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// GB18030 has no `String.Encoding` constant — it is only reachable
    /// through CoreFoundation's encoding tables.
    static let gb18030: String.Encoding = {
        let cfEncoding = CFStringEncodings.GB_18030_2000
        let bridged = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(cfEncoding.rawValue))
        return String.Encoding(rawValue: UInt(bridged))
    }()

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    /// RTF (and .doc that is really RTF) via the platform's own reader.
    private static func richTextMarkdown(from data: Data) throws -> String {
        var attributed: NSAttributedString?
        attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil)
        if attributed == nil {
            attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil)
        }
        guard let text = attributed?.string else {
            throw ConversionError.cannotOpenSource
        }
        return Markup.markdown(fromPlainText: text)
    }
}

// MARK: - Word (.docx)

enum DocxReader {

    static func markdown(from data: Data) throws -> String {
        let archive = try ZipArchive(data: data)
        let candidates = ["word/document.xml", "word/document2.xml"]
        var documentXML: Data?
        for name in candidates where archive.contains(name) {
            documentXML = try archive.contents(of: name)
            break
        }
        guard let xml = documentXML else { throw ZipError.entryNotFound("word/document.xml") }

        let parser = XMLParser(data: xml)
        let delegate = DocxDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            // Malformed XML still usually yields most of the text.
            if delegate.blocks.isEmpty { throw ConversionError.cannotOpenSource }
            return delegate.blocks.joined(separator: "\n\n")
        }
        return delegate.blocks.joined(separator: "\n\n")
    }
}

private final class DocxDelegate: NSObject, XMLParserDelegate {

    var blocks: [String] = []

    private var paragraph = ""
    private var paragraphStyle: String?
    private var paragraphIsList = false
    private var runBuffer = ""
    private var inText = false
    private var boldDepth = 0
    private var italicDepth = 0
    private var boldOff = false
    private var italicOff = false

    private var inTable = false
    private var tableRows: [[String]] = []
    private var currentRow: [String] = []
    private var currentCell: [String] = []

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "w:p":
            paragraph = ""
            paragraphStyle = nil
            paragraphIsList = false
            boldDepth = 0
            italicDepth = 0
            boldOff = false
            italicOff = false

        case "w:pStyle":
            paragraphStyle = attributeDict["w:val"]

        case "w:numPr":
            paragraphIsList = true

        case "w:t":
            inText = true
            runBuffer = ""

        case "w:br", "w:cr":
            paragraph += "\n"

        case "w:tab":
            paragraph += "\t"

        case "w:b":
            if isOff(attributeDict["w:val"]) { boldOff = true } else { boldDepth += 1 }

        case "w:i":
            if isOff(attributeDict["w:val"]) { italicOff = true } else { italicDepth += 1 }

        case "w:tbl":
            inTable = true
            tableRows = []

        case "w:tr":
            currentRow = []

        case "w:tc":
            currentCell = []

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { runBuffer += string }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "w:t":
            inText = false
            var piece = runBuffer
            runBuffer = ""
            guard !piece.isEmpty else { break }
            let isBold = boldDepth > 0 && !boldOff
            let isItalic = italicDepth > 0 && !italicOff
            if isBold && isItalic {
                piece = "***\(piece)***"
            } else if isBold {
                piece = "**\(piece)**"
            } else if isItalic {
                piece = "*\(piece)*"
            }
            paragraph += piece

        case "w:b":
            boldDepth = max(0, boldDepth - 1)

        case "w:i":
            italicDepth = max(0, italicDepth - 1)

        case "w:p":
            emitParagraph()

        case "w:tc":
            let value = currentCell.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            currentRow.append(value)
            currentCell = []

        case "w:tr":
            if !currentRow.isEmpty { tableRows.append(currentRow) }
            currentRow = []

        case "w:tbl":
            inTable = false
            if let rendered = renderTable(tableRows) { blocks.append(rendered) }
            tableRows = []

        default:
            break
        }
    }

    private func isOff(_ value: String?) -> Bool {
        guard let value else { return false }
        return value == "0" || value.lowercased() == "false" || value.lowercased() == "off"
    }

    private func emitParagraph() {
        let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        paragraph = ""

        if inTable {
            if !text.isEmpty { currentCell.append(text) }
            return
        }
        guard !text.isEmpty else { return }

        if let style = paragraphStyle, style.lowercased().hasPrefix("heading"),
           let digit = style.compactMap({ $0.wholeNumberValue }).first {
            let level = min(max(digit, 1), 6)
            blocks.append(String(repeating: "#", count: level) + " " + text)
        } else if paragraphIsList {
            blocks.append("- " + text)
        } else {
            blocks.append(text)
        }
    }

    private func renderTable(_ rows: [[String]]) -> String? {
        guard let first = rows.first, !first.isEmpty else { return nil }
        let columns = rows.map(\.count).max() ?? first.count
        guard columns > 0 else { return nil }

        var header = first
        while header.count < columns { header.append("") }

        var lines: [String] = []
        lines.append("| " + header.joined(separator: " | ") + " |")
        lines.append("| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |")
        for row in rows.dropFirst() {
            var cells = row
            while cells.count < columns { cells.append("") }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - EPUB

enum EpubReader {

    static func markdown(from data: Data) throws -> String {
        let archive = try ZipArchive(data: data)

        var packagePath: String?
        if archive.contains("META-INF/container.xml"),
           let container = try? archive.contents(of: "META-INF/container.xml"),
           let containerXML = String(data: container, encoding: .utf8) {
            packagePath = Markup.matches(#"full-path=["']([^"']+)["']"#, in: containerXML).first
        }
        if packagePath == nil {
            packagePath = archive.entries.first { $0.name.lowercased().hasSuffix(".opf") }?.name
        }
        guard let packagePath else { throw ZipError.entryNotFound("content.opf") }

        let packageData = try archive.contents(of: packagePath)
        let packageXML = String(data: packageData, encoding: .utf8) ?? ""
        let baseDirectory = (packagePath as NSString).deletingLastPathComponent

        // Manifest: id → href
        var manifest: [String: String] = [:]
        for tag in Markup.tags(#"<item\b[^>]*>"#, in: packageXML) {
            guard let identifier = attribute("id", in: tag),
                  let href = attribute("href", in: tag) else { continue }
            manifest[identifier] = href
        }

        // Spine: reading order
        var readingOrder: [String] = []
        for tag in Markup.tags(#"<itemref\b[^>]*>"#, in: packageXML) {
            guard let idref = attribute("idref", in: tag), let href = manifest[idref] else { continue }
            readingOrder.append(href)
        }
        if readingOrder.isEmpty {
            readingOrder = archive.entries
                .filter { ["xhtml", "html", "htm"].contains(($0.name as NSString).pathExtension.lowercased()) }
                .map(\.name)
                .sorted()
        }

        var chapters: [String] = []
        for href in readingOrder {
            let path = resolve(href, relativeTo: baseDirectory)
            guard archive.contains(path), let raw = try? archive.contents(of: path) else { continue }
            let html = DocumentProcessor.decodeText(raw)
            let chapter = Markup.markdown(fromHTML: html)
            if !chapter.isEmpty { chapters.append(chapter) }
        }
        guard !chapters.isEmpty else { throw ConversionError.cannotOpenSource }

        var output = chapters.joined(separator: "\n\n")

        // Keep the book title from the OPF when the text has no heading of its own.
        if !output.hasPrefix("#"),
           let title = Markup.matches(#"<dc:title[^>]*>(.*?)</dc:title>"#, in: packageXML).first {
            let clean = Markup.decodeEntities(title).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { output = "# \(clean)\n\n" + output }
        }
        return output
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        Markup.matches(name + #"\s*=\s*["']([^"']*)["']"#, in: tag).first
    }

    /// Resolve an href against the directory holding the OPF.
    private static func resolve(_ href: String, relativeTo base: String) -> String {
        var path = href
        if let hash = path.firstIndex(of: "#") { path = String(path[path.startIndex..<hash]) }
        path = path.removingPercentEncoding ?? path
        if path.hasPrefix("/") { return String(path.dropFirst()) }

        var parts: [String] = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for component in path.split(separator: "/").map(String.init) {
            if component == "." || component.isEmpty { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(component)
        }
        return parts.joined(separator: "/")
    }
}
