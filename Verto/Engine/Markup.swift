//
//  Markup.swift
//  万能转换
//
//  Text-format plumbing: HTML ⇄ Markdown ⇄ plain text, plus the XML
//  escaping the docx/epub writers need. Markdown is the pivot format —
//  every reader normalises to it and every writer renders from it.
//

import Foundation

enum Markup {

    // MARK: - Escaping

    static func escapeHTML(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        return out
    }

    static func escapeXML(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }

    /// Drop characters that are illegal in XML 1.0 so the docx/epub
    /// writers never emit a document Word or a reader will reject.
    static func sanitizeXML(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                out.append(scalar)
            case 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                out.append(scalar)
            default:
                break
            }
        }
        return String(out)
    }

    // MARK: - Entities

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "mdash": "—", "ndash": "–", "hellip": "…",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "laquo": "«", "raquo": "»", "times": "×", "divide": "÷",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°",
        "middot": "·", "bull": "•", "sect": "§", "para": "¶",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓",
        "le": "≤", "ge": "≥", "ne": "≠", "plusmn": "±",
        "frac12": "½", "frac14": "¼", "sup2": "²", "sup3": "³",
        "agrave": "à", "eacute": "é", "egrave": "è", "ccedil": "ç",
        "uuml": "ü", "ouml": "ö", "auml": "ä", "szlig": "ß",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "pi": "π", "omega": "ω", "sigma": "σ", "mu": "μ",
        "infin": "∞", "radic": "√", "sum": "∑", "prod": "∏"
    ]

    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var out = ""
        out.reserveCapacity(input.count)

        var iterator = input.makeIterator()
        var pending: Character? = nil

        func next() -> Character? {
            if let held = pending { pending = nil; return held }
            return iterator.next()
        }

        while let character = next() {
            guard character == "&" else { out.append(character); continue }

            var buffer = ""
            var terminated = false
            var consumed = 0

            while consumed < 12, let peek = next() {
                consumed += 1
                if peek == ";" { terminated = true; break }
                if peek == "&" || peek == "<" { pending = peek; break }
                buffer.append(peek)
            }

            guard terminated, !buffer.isEmpty else {
                out.append("&")
                out.append(buffer)
                continue
            }

            if buffer.hasPrefix("#") {
                let digits = String(buffer.dropFirst())
                let value: UInt32?
                if digits.lowercased().hasPrefix("x") {
                    value = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    value = UInt32(digits)
                }
                if let value, let scalar = Unicode.Scalar(value) {
                    out.append(Character(scalar))
                } else {
                    out.append("&\(buffer);")
                }
                continue
            }

            if let replacement = namedEntities[buffer.lowercased()] {
                out.append(replacement)
            } else {
                out.append("&\(buffer);")
            }
        }
        return out
    }

    // MARK: - Regex helper

    static func replace(_ pattern: String,
                        in text: String,
                        with template: String,
                        caseInsensitive: Bool = true) -> String {
        var options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let slice = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[slice])
        }
    }

    /// Full (group 0) matches — handy for scanning XML tags.
    static func tags(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let slice = Range(match.range, in: text) else { return nil }
            return String(text[slice])
        }
    }

    private static func collapseBlankLines(_ text: String) -> String {
        var out = replace(#"\n{3,}"#, in: text, with: "\n\n", caseInsensitive: false)
        out = replace(#"[ \t]+\n"#, in: out, with: "\n", caseInsensitive: false)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTML → Markdown

    static func markdown(fromHTML html: String) -> String {
        var text = html
        var protected: [String] = []

        // Code blocks and tables need structural handling, so lift them
        // out of the stream before the line-oriented rules run over the rest.
        text = lift(#"(?s)<pre\b[^>]*>(.*?)</pre>"#, from: text, into: &protected) { inner in
            var code = replace(#"<[^>]+>"#, in: inner, with: "")
            code = decodeEntities(code)
            return "```\n" + code.trimmingCharacters(in: .newlines) + "\n```"
        }
        text = lift(#"(?s)<table\b[^>]*>(.*?)</table>"#, from: text, into: &protected) { inner in
            markdownTable(fromHTMLRows: inner)
        }

        text = replace(#"(?s)<script\b[^>]*>.*?</script>"#, in: text, with: "")
        text = replace(#"(?s)<style\b[^>]*>.*?</style>"#, in: text, with: "")
        text = replace(#"(?s)<!--.*?-->"#, in: text, with: "")
        text = replace(#"(?s)<!DOCTYPE[^>]*>"#, in: text, with: "")
        text = replace(#"(?s)<head\b[^>]*>.*?</head>"#, in: text, with: "")
        text = replace(#"(?s)<nav\b[^>]*>.*?</nav>"#, in: text, with: "")

        // Block level
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            text = replace(#"<h\#(level)\b[^>]*>(.*?)</h\#(level)>"#,
                           in: text,
                           with: "\n\n\(hashes) $1\n\n")
        }
        text = replace(#"(?s)<blockquote\b[^>]*>(.*?)</blockquote>"#, in: text, with: "\n\n> $1\n\n")
        text = replace(#"(?s)<li\b[^>]*>(.*?)</li>"#, in: text, with: "\n- $1")
        text = replace(#"(?s)<(ul|ol)\b[^>]*>(.*?)</\1>"#, in: text, with: "\n$2\n")
        text = replace(#"(?s)<p\b[^>]*>(.*?)</p>"#, in: text, with: "\n\n$1\n\n")
        text = replace(#"(?s)<div\b[^>]*>(.*?)</div>"#, in: text, with: "\n$1\n")
        text = replace(#"<br\s*/?>"#, in: text, with: "\n")
        text = replace(#"<hr\s*/?>"#, in: text, with: "\n\n---\n\n")

        // Inline level
        text = replace(#"<img\b[^>]*alt=["']([^"']*)["'][^>]*src=["']([^"']*)["'][^>]*>"#,
                       in: text, with: "![$1]($2)")
        text = replace(#"<img\b[^>]*src=["']([^"']*)["'][^>]*>"#, in: text, with: "![]($1)")
        text = replace(#"(?s)<a\b[^>]*href=["']([^"']*)["'][^>]*>(.*?)</a>"#,
                       in: text, with: "[$2]($1)")
        text = replace(#"(?s)<(strong|b)\b[^>]*>(.*?)</\1>"#, in: text, with: "**$2**")
        text = replace(#"(?s)<(em|i)\b[^>]*>(.*?)</\1>"#, in: text, with: "*$2*")
        text = replace(#"(?s)<code\b[^>]*>(.*?)</code>"#, in: text, with: "`$1`")
        text = replace(#"(?s)<(del|s|strike)\b[^>]*>(.*?)</\1>"#, in: text, with: "~~$2~~")

        // Everything else is markup we don't model — drop the tags.
        text = replace(#"<[^>]+>"#, in: text, with: "")
        text = decodeEntities(text)
        text = replace(#"(?m)^>[ \t]*$"#, in: text, with: "")

        // Put the lifted code blocks and tables back.
        for (index, block) in protected.enumerated() {
            text = text.replacingOccurrences(of: "\u{0001}\(index)\u{0001}", with: block)
        }
        return collapseBlankLines(text)
    }

    /// Replaces every match of `pattern` with a placeholder token, handing
    /// the captured group to `transform` for structural rendering.
    private static func lift(_ pattern: String,
                             from text: String,
                             into store: inout [String],
                             transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        var result = text
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        let found = regex.matches(in: result, options: [], range: range)

        for match in found.reversed() {
            guard match.numberOfRanges > 1,
                  let full = Range(match.range, in: result),
                  let inner = Range(match.range(at: 1), in: result) else { continue }
            let rendered = transform(String(result[inner]))
            let token = "\u{0001}\(store.count)\u{0001}"
            store.append(rendered)
            result.replaceSubrange(full, with: token)
        }
        return result
    }

    private static func markdownTable(fromHTMLRows inner: String) -> String {
        guard let rowRegex = try? NSRegularExpression(pattern: #"(?s)<tr\b[^>]*>(.*?)</tr>"#,
                                                     options: [.caseInsensitive]),
              let cellRegex = try? NSRegularExpression(pattern: #"(?s)<t[hd]\b[^>]*>(.*?)</t[hd]>"#,
                                                       options: [.caseInsensitive]) else {
            return ""
        }

        var header: [String] = []
        var body: [[String]] = []

        let rowRange = NSRange(inner.startIndex..<inner.endIndex, in: inner)
        for rowMatch in rowRegex.matches(in: inner, options: [], range: rowRange) {
            guard rowMatch.numberOfRanges > 1,
                  let captured = Range(rowMatch.range(at: 1), in: inner) else { continue }
            let rowHTML = String(inner[captured])

            var cells: [String] = []
            let cellRange = NSRange(rowHTML.startIndex..<rowHTML.endIndex, in: rowHTML)
            for cellMatch in cellRegex.matches(in: rowHTML, options: [], range: cellRange) {
                guard cellMatch.numberOfRanges > 1,
                      let cellCaptured = Range(cellMatch.range(at: 1), in: rowHTML) else { continue }
                var value = replace(#"<[^>]+>"#, in: String(rowHTML[cellCaptured]), with: "")
                value = decodeEntities(value)
                value = replace(#"\s+"#, in: value, with: " ", caseInsensitive: false)
                cells.append(value.trimmingCharacters(in: .whitespaces))
            }
            guard !cells.isEmpty else { continue }

            if header.isEmpty && rowHTML.lowercased().contains("<th") {
                header = cells
            } else {
                body.append(cells)
            }
        }

        if header.isEmpty {
            guard let first = body.first else { return "" }
            header = first
            body.removeFirst()
        }

        let columns = max(header.count, body.map(\.count).max() ?? 0)
        guard columns > 0 else { return "" }

        var headerCells = header
        while headerCells.count < columns { headerCells.append("") }

        var lines: [String] = []
        lines.append("| " + headerCells.joined(separator: " | ") + " |")
        lines.append("| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |")
        for row in body {
            var cells = row
            while cells.count < columns { cells.append("") }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Markdown → HTML

    private static func inlineHTML(_ text: String) -> String {
        var out = escapeHTML(text)
        out = replace(#"!\[([^\]]*)\]\(([^)\s]+)\)"#, in: out, with: #"<img src="$2" alt="$1"/>"#)
        out = replace(#"\[([^\]]+)\]\(([^)\s]+)\)"#, in: out, with: #"<a href="$2">$1</a>"#)
        out = replace(#"`([^`]+)`"#, in: out, with: "<code>$1</code>")
        out = replace(#"\*\*([^*]+)\*\*"#, in: out, with: "<strong>$1</strong>")
        out = replace(#"__([^_]+)__"#, in: out, with: "<strong>$1</strong>")
        out = replace(#"~~([^~]+)~~"#, in: out, with: "<del>$1</del>")
        out = replace(#"\*([^*]+)\*"#, in: out, with: "<em>$1</em>")
        out = replace(#"(?<![A-Za-z0-9_])_([^_]+)_(?![A-Za-z0-9_])"#, in: out, with: "<em>$1</em>")
        return out
    }

    /// Body-only HTML. `fragment` is what the docx/epub writers embed.
    static func htmlBody(fromMarkdown markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [String] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var quoteLines: [String] = []
        var codeLines: [String] = []
        var inCode = false
        var codeLanguage = ""

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append("<p>" + inlineHTML(paragraph.joined(separator: " ")) + "</p>")
            paragraph.removeAll()
        }
        func flushList() {
            guard !listItems.isEmpty else { return }
            let items = listItems.map { "<li>" + inlineHTML($0) + "</li>" }.joined(separator: "\n")
            blocks.append("<ul>\n" + items + "\n</ul>")
            listItems.removeAll()
        }
        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            let body = quoteLines.map { "<p>" + inlineHTML($0) + "</p>" }.joined(separator: "\n")
            blocks.append("<blockquote>\n" + body + "\n</blockquote>")
            quoteLines.removeAll()
        }
        func flushPending() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if inCode {
                if line.hasPrefix("```") {
                    let code = escapeHTML(codeLines.joined(separator: "\n"))
                    let languageClass = codeLanguage.isEmpty ? "" : " class=\"language-\(codeLanguage)\""
                    blocks.append("<pre><code\(languageClass)>\(code)</code></pre>")
                    codeLines.removeAll()
                    codeLanguage = ""
                    inCode = false
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }

            if line.hasPrefix("```") {
                flushPending()
                inCode = true
                codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if line.isEmpty {
                flushPending()
                continue
            }

            if let heading = firstMatch(#"^(#{1,6})\s+(.*)$"#, in: line) {
                flushPending()
                let level = heading.0.count
                blocks.append("<h\(level)>" + inlineHTML(heading.1) + "</h\(level)>")
                continue
            }

            if line == "---" || line == "***" || line == "___" {
                flushPending()
                blocks.append("<hr/>")
                continue
            }

            if line.hasPrefix("> ") || line == ">" {
                flushParagraph()
                flushList()
                quoteLines.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            if let item = firstMatch(#"^([-*+]|\d+\.)\s+(.*)$"#, in: line) {
                flushParagraph()
                flushQuote()
                listItems.append(item.1)
                continue
            }

            flushList()
            flushQuote()
            paragraph.append(line)
        }

        if inCode, !codeLines.isEmpty {
            let code = escapeHTML(codeLines.joined(separator: "\n"))
            blocks.append("<pre><code>\(code)</code></pre>")
        }
        flushPending()

        return blocks.joined(separator: "\n")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text,
                                           options: [],
                                           range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.numberOfRanges > 2,
              let first = Range(match.range(at: 1), in: text),
              let second = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return (String(text[first]), String(text[second]))
    }

    // MARK: - Markdown → plain text

    static func plainText(fromMarkdown markdown: String) -> String {
        var text = markdown
        text = replace(#"```[^\n]*\n"#, in: text, with: "")
        text = replace(#"^#{1,6}\s+"#, in: text, with: "")
        text = replace(#"^\s*>\s?"#, in: text, with: "")
        text = replace(#"^\s*[-*+]\s+"#, in: text, with: "· ")
        text = replace(#"^\s*\d+\.\s+"#, in: text, with: "")
        text = replace(#"^\s*(-{3,}|\*{3,}|_{3,})\s*$"#, in: text, with: "")
        text = replace(#"!\[([^\]]*)\]\(([^)\s]+)\)"#, in: text, with: "$1")
        text = replace(#"\[([^\]]+)\]\(([^)\s]+)\)"#, in: text, with: "$1 ($2)")
        text = replace(#"(\*\*|__|~~)"#, in: text, with: "")
        text = replace(#"`"#, in: text, with: "")
        text = replace(#"(\*|_)"#, in: text, with: "")
        return collapseBlankLines(text)
    }

    /// Reading a .txt into the Markdown pivot: paragraphs are separated
    /// by blank lines, and nothing else needs to change.
    static func markdown(fromPlainText text: String) -> String {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalised.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if paragraphs.isEmpty { return normalised.trimmingCharacters(in: .whitespacesAndNewlines) }
        return paragraphs.joined(separator: "\n\n")
    }

    // MARK: - Titles

    /// Best-effort document title: first heading, else first non-empty line.
    static func title(fromMarkdown markdown: String, fallback: String) -> String {
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var candidate = line
            if candidate.hasPrefix("#") {
                candidate = candidate.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            }
            candidate = plainText(fromMarkdown: candidate).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return String(candidate.prefix(120))
            }
        }
        return fallback
    }
}
