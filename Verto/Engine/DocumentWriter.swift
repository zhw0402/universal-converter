//
//  DocumentWriter.swift
//  万能转换
//
//  Builds Word (.docx) and EPUB packages from the Markdown pivot,
//  plus the standalone HTML document used by the .html target.
//

import Foundation

enum DocumentWriter {

    // MARK: - HTML

    static func htmlDocument(markdown: String, title: String) -> String {
        let body = Markup.htmlBody(fromMarkdown: markdown)
        let safeTitle = Markup.escapeHTML(title)
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title>\(safeTitle)</title>
        <style>
        body{font-family:-apple-system,"PingFang SC","Helvetica Neue",sans-serif;line-height:1.75;
        max-width:44rem;margin:2rem auto;padding:0 1.1rem;color:#1c1c1e;background:#fdfdfd}
        h1,h2,h3,h4,h5,h6{line-height:1.35;margin:1.8em 0 .6em}
        h1{font-size:1.7em}h2{font-size:1.4em}h3{font-size:1.2em}
        pre{background:#f4f4f6;padding:.9em 1em;border-radius:8px;overflow-x:auto;font-size:.9em}
        code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
        p>code,li>code{background:#f0f0f3;padding:.1em .35em;border-radius:4px}
        blockquote{margin:1.2em 0;padding:.2em 1em;border-left:3px solid #d0d0d5;color:#555}
        table{border-collapse:collapse;width:100%;margin:1.2em 0}
        th,td{border:1px solid #ddd;padding:.45em .7em;text-align:left}
        th{background:#f6f6f8}
        img{max-width:100%}
        hr{border:0;border-top:1px solid #e2e2e6;margin:2em 0}
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    // MARK: - Shared markdown block model

    private struct Paragraph {
        var style: String?
        var text: String
        var isListItem: Bool = false
    }

    private static func headingLevel(_ line: String) -> Int? {
        var count = 0
        for character in line {
            guard character == "#" else { break }
            count += 1
        }
        guard (1...6).contains(count) else { return nil }
        let rest = line.dropFirst(count)
        guard rest.hasPrefix(" ") else { return nil }
        return count
    }

    private static func listBody(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        var digits = ""
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            digits.append(line[index])
            index = line.index(after: index)
        }
        guard !digits.isEmpty, index < line.endIndex, line[index] == "." else { return nil }
        let afterDot = line.index(after: index)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return String(line[line.index(after: afterDot)...])
    }

    private static func paragraphs(fromMarkdown markdown: String) -> [Paragraph] {
        var result: [Paragraph] = []
        var buffer: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(Paragraph(style: nil, text: buffer.joined(separator: " ")))
            buffer.removeAll()
        }

        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if inCode {
                if line.hasPrefix("```") {
                    for codeLine in codeLines {
                        result.append(Paragraph(style: "Code", text: codeLine))
                    }
                    codeLines.removeAll()
                    inCode = false
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }

            if line.hasPrefix("```") {
                flush()
                inCode = true
                continue
            }

            if line.isEmpty {
                flush()
                continue
            }

            if let level = headingLevel(line) {
                flush()
                let text = String(line.dropFirst(level + 1))
                result.append(Paragraph(style: "Heading\(level)", text: text))
                continue
            }

            if line == "---" || line == "***" || line == "___" {
                flush()
                result.append(Paragraph(style: "Rule", text: ""))
                continue
            }

            if line.hasPrefix(">") {
                flush()
                let text = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                result.append(Paragraph(style: "Quote", text: text))
                continue
            }

            if let body = listBody(line) {
                flush()
                result.append(Paragraph(style: nil, text: body, isListItem: true))
                continue
            }

            buffer.append(line)
        }

        if inCode {
            for codeLine in codeLines {
                result.append(Paragraph(style: "Code", text: codeLine))
            }
        }
        flush()
        return result
    }

    // MARK: - Word (.docx)

    /// Inline markdown → a sequence of OOXML runs, so bold and italic
    /// survive the trip into Word.
    private static func runs(fromInline text: String) -> String {
        var output = ""
        var buffer = ""
        var bold = false
        var italic = false

        func flush() {
            guard !buffer.isEmpty else { return }
            var properties = ""
            if bold { properties += "<w:b/>" }
            if italic { properties += "<w:i/>" }
            let runProperties = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
            let escaped = Markup.escapeXML(Markup.sanitizeXML(buffer))
            output += "<w:r>\(runProperties)<w:t xml:space=\"preserve\">\(escaped)</w:t></w:r>"
            buffer = ""
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "*" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "*" {
                    flush()
                    bold.toggle()
                    index = text.index(after: next)
                    continue
                }
                flush()
                italic.toggle()
                index = next
                continue
            }
            if character == "`" {
                flush()
                index = text.index(after: index)
                continue
            }
            buffer.append(character)
            index = text.index(after: index)
        }
        flush()
        if output.isEmpty {
            output = "<w:r><w:t xml:space=\"preserve\"></w:t></w:r>"
        }
        return output
    }

    private static let styleDefinitions: String = {
        var styles = #"<w:style w:type="paragraph" w:default="1" w:styleId="原速"><w:name w:val="原速"/><w:qFormat/></w:style>"#
        let sizes = [32, 28, 25, 22, 20, 18]
        for level in 1...6 {
            let size = sizes[level - 1]
            styles += #"<w:style w:type="paragraph" w:styleId="Heading\#(level)"><w:name w:val="heading \#(level)"/><w:basedOn w:val="原速"/><w:next w:val="原速"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val="\#(level - 1)"/></w:pPr><w:rPr><w:b/><w:sz w:val="\#(size)"/><w:szCs w:val="\#(size)"/></w:rPr></w:style>"#
        }
        styles += #"<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="原速"/><w:pPr><w:ind w:left="720"/></w:pPr><w:rPr><w:i/><w:color w:val="555555"/></w:rPr></w:style>"#
        styles += #"<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="原速"/><w:pPr><w:shd w:val="clear" w:fill="F4F4F6"/></w:pPr><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo"/></w:rPr></w:style>"#
        styles += #"<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>"#
        return styles
    }()

    static func docxData(markdown: String) -> Data {
        let items = paragraphs(fromMarkdown: markdown)

        var body = ""
        for item in items {
            let text = item.isListItem ? "• " + item.text : item.text
            body += "<w:p>"
            if let style = item.style {
                body += "<w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr>"
            }
            body += runs(fromInline: text)
            body += "</w:p>"
        }
        if items.isEmpty {
            body = "<w:p/>"
        }

        let document = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\#(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>
        """#

        let styles = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\#(styleDefinitions)</w:styles>
        """#

        let contentTypes = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
        """#

        let rootRelationships = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
        """#

        let documentRelationships = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """#

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let core = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:creator>万能转换</dc:creator><cp:lastModifiedBy>万能转换</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">\#(timestamp)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\#(timestamp)</dcterms:modified></cp:coreProperties>
        """#

        let app = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>万能转换</Application></Properties>
        """#

        var builder = ZipBuilder()
        builder.add("[Content_Types].xml", text: contentTypes)
        builder.add("_rels/.rels", text: rootRelationships)
        builder.add("word/document.xml", text: document)
        builder.add("word/styles.xml", text: styles)
        builder.add("word/_rels/document.xml.rels", text: documentRelationships)
        builder.add("docProps/core.xml", text: core)
        builder.add("docProps/app.xml", text: app)
        return builder.finalized()
    }

    // MARK: - EPUB

    private struct Chapter {
        var title: String
        var markdown: String
    }

    /// Split on top-level headings so readers get a real table of contents.
    private static func chapters(fromMarkdown markdown: String, fallbackTitle: String) -> [Chapter] {
        var chapters: [Chapter] = []
        var currentTitle: String?
        var buffer: [String] = []

        func flush() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll()
            guard !text.isEmpty else { return }
            let title = currentTitle ?? Markup.title(fromMarkdown: text, fallback: fallbackTitle)
            chapters.append(Chapter(title: title, markdown: text))
            currentTitle = nil
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if rawLine.hasPrefix("# ") {
                flush()
                currentTitle = Markup.plainText(fromMarkdown: String(rawLine.dropFirst(2)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                buffer.append(rawLine)
                continue
            }
            buffer.append(rawLine)
        }
        flush()

        if chapters.isEmpty {
            let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            return [Chapter(title: fallbackTitle, markdown: text.isEmpty ? fallbackTitle : text)]
        }
        return chapters
    }

    static func epubData(markdown: String, title: String) -> Data {
        let bookChapters = chapters(fromMarkdown: markdown, fallbackTitle: title)
        let bookIdentifier = "urn:uuid:" + UUID().uuidString
        let safeTitle = Markup.escapeXML(Markup.sanitizeXML(title))
        let timestamp = ISO8601DateFormatter().string(from: Date())

        var builder = ZipBuilder()

        // The mimetype entry must come first and must not be compressed.
        builder.add("mimetype", text: "application/epub+zip", allowCompression: false)

        let container = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """#
        builder.add("META-INF/container.xml", text: container)

        let css = """
        body{font-family:-apple-system,"PingFang SC",serif;line-height:1.75;margin:1em;color:#1c1c1e}
        h1,h2,h3,h4,h5,h6{line-height:1.35;margin:1.4em 0 .5em}
        pre{background:#f4f4f6;padding:.8em;border-radius:6px;white-space:pre-wrap;font-size:.9em}
        code{font-family:Menlo,monospace;font-size:.9em}
        blockquote{margin:1em 0;padding:.2em .9em;border-left:3px solid #ccc;color:#555}
        table{border-collapse:collapse;width:100%}
        th,td{border:1px solid #ddd;padding:.35em .55em;text-align:left}
        img{max-width:100%}
        """
        builder.add("OEBPS/style.css", text: css)

        var manifest = #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#
        manifest += #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#
        manifest += #"<item id="css" href="style.css" media-type="text/css"/>"#
        var spine = ""
        var navigation = ""

        for (index, chapter) in bookChapters.enumerated() {
            let filename = "chapter-\(index + 1).xhtml"
            let identifier = "chapter-\(index + 1)"
            let chapterTitle = Markup.escapeXML(Markup.sanitizeXML(chapter.title))
            let body = Markup.htmlBody(fromMarkdown: chapter.markdown)

            let xhtml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN" xml:lang="zh-CN">
            <head><meta charset="utf-8"/><title>\(chapterTitle)</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
            <body>
            \(body)
            </body>
            </html>
            """
            builder.add("OEBPS/\(filename)", text: xhtml)
            manifest += #"<item id="\#(identifier)" href="\#(filename)" media-type="application/xhtml+xml"/>"#
            spine += #"<itemref idref="\#(identifier)"/>"#
            navigation += #"<li><a href="\#(filename)">\#(chapterTitle)</a></li>"#
        }

        let package = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="zh-CN">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="bookid">\(bookIdentifier)</dc:identifier>
        <dc:title>\(safeTitle)</dc:title>
        <dc:language>zh-CN</dc:language>
        <dc:creator>万能转换</dc:creator>
        <meta property="dcterms:modified">\(timestamp)</meta>
        </metadata>
        <manifest>\(manifest)</manifest>
        <spine toc="ncx">\(spine)</spine>
        </package>
        """
        builder.add("OEBPS/content.opf", text: package)

        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="zh-CN" xml:lang="zh-CN">
        <head><meta charset="utf-8"/><title>目录</title><link rel="stylesheet" type="text/css" href="style.css"/></head>
        <body>
        <nav epub:type="toc" id="toc"><h1>目录</h1><ol>\(navigation)</ol></nav>
        </body>
        </html>
        """
        builder.add("OEBPS/nav.xhtml", text: nav)

        var navPoints = ""
        for (index, chapter) in bookChapters.enumerated() {
            let chapterTitle = Markup.escapeXML(Markup.sanitizeXML(chapter.title))
            navPoints += """
            <navPoint id="navPoint-\(index + 1)" playOrder="\(index + 1)"><navLabel><text>\(chapterTitle)</text></navLabel><content src="chapter-\(index + 1).xhtml"/></navPoint>
            """
        }
        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
        <head><meta name="dtb:uid" content="\(bookIdentifier)"/></head>
        <docTitle><text>\(safeTitle)</text></docTitle>
        <navMap>\(navPoints)</navMap>
        </ncx>
        """
        builder.add("OEBPS/toc.ncx", text: ncx)

        return builder.finalized()
    }
}
