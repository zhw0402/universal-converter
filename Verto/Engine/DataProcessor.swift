//
//  DataProcessor.swift
//  万能转换
//
//  JSON ⇄ CSV ⇄ XML ⇄ plist. Everything is read into one small value
//  tree and rendered back out, so every pair of formats is supported
//  without a combinatorial explosion of converters.
//

import Foundation
import CoreFoundation
import UniformTypeIdentifiers

indirect enum DataValue {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DataValue])
    case object([(key: String, value: DataValue)])
}

enum DataDocumentKind: String {
    case json, csv, xml, plist

    var displayName: String { rawValue.uppercased() }

    static func detected(from type: UTType) -> DataDocumentKind? {
        switch type.identifier {
        case "public.json":                        return .json
        case "public.comma-separated-values-text": return .csv
        case "public.xml":                         return .xml
        case "com.apple.property-list":            return .plist
        default: break
        }
        switch type.preferredFilenameExtension?.lowercased() ?? "" {
        case "json":            return .json
        case "csv":             return .csv
        case "xml":             return .xml
        case "plist":           return .plist
        default:                return nil
        }
    }
}

enum DataProcessor {

    static let outputFormats: [OutputFormat] = [.json, .csv, .xml, .plist]

    static func kind(for sourceType: UTType) -> DataDocumentKind? {
        DataDocumentKind.detected(from: sourceType)
    }

    static func convert(source: URL,
                        kind: DataDocumentKind,
                        to format: OutputFormat,
                        outputDirectory: URL) throws -> URL {
        let data = try Data(contentsOf: source)
        let value = try decode(data, kind: kind)

        let baseName = source.deletingPathExtension().lastPathComponent
        let destination = ConversionEngine.uniqueDestination(in: outputDirectory,
                                                             baseName: baseName,
                                                             fileExtension: format.fileExtension)

        switch format {
        case .json:
            try encodeJSON(value).write(to: destination)
        case .plist:
            try encodePlist(value).write(to: destination)
        case .xml:
            try Data(encodeXML(value).utf8).write(to: destination)
        case .csv:
            try Data(encodeCSV(value).utf8).write(to: destination)
        default:
            throw ConversionError.unsupportedConversion
        }
        return destination
    }

    // MARK: - Decoding

    static func decode(_ data: Data, kind: DataDocumentKind) throws -> DataValue {
        switch kind {
        case .json:
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return fromFoundation(object)

        case .plist:
            let object = try PropertyListSerialization.propertyList(from: data,
                                                                   options: [],
                                                                   format: nil)
            return fromFoundation(object)

        case .csv:
            let text = DocumentProcessor.decodeText(data)
            return rowsToValue(parseCSV(text))

        case .xml:
            let parser = XMLParser(data: data)
            let delegate = XMLValueDelegate()
            parser.delegate = delegate
            parser.shouldProcessNamespaces = false
            guard parser.parse(), let value = delegate.result else {
                throw ConversionError.cannotOpenSource
            }
            return value
        }
    }

    static func fromFoundation(_ object: Any) -> DataValue {
        if object is NSNull { return .null }
        if let number = object as? NSNumber {
            // NSNumber wraps booleans too — the CFBoolean check tells them apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        if let text = object as? String { return .string(text) }
        if let array = object as? [Any] { return .array(array.map(fromFoundation)) }
        if let dictionary = object as? [String: Any] {
            let pairs = dictionary.keys.sorted().map { (key: $0, value: fromFoundation(dictionary[$0] as Any)) }
            return .object(pairs)
        }
        if let dictionary = object as? NSDictionary {
            var pairs: [(key: String, value: DataValue)] = []
            for (key, value) in dictionary {
                pairs.append((key: String(describing: key), value: fromFoundation(value)))
            }
            return .object(pairs)
        }
        return .string(String(describing: object))
    }

    private static func toFoundation(_ value: DataValue) -> Any {
        switch value {
        case .null:            return NSNull()
        case .bool(let flag):  return flag
        case .number(let num): return num
        case .string(let text): return text
        case .array(let items): return items.map(toFoundation)
        case .object(let pairs):
            var dictionary: [String: Any] = [:]
            for pair in pairs { dictionary[pair.key] = toFoundation(pair.value) }
            return dictionary
        }
    }

    // MARK: - Encoding

    static func encodeJSON(_ value: DataValue) throws -> Data {
        try JSONSerialization.data(withJSONObject: toFoundation(value),
                                   options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    static func encodePlist(_ value: DataValue) throws -> Data {
        let object = toFoundation(value)
        // Property lists need a dictionary or array at the root.
        let rooted: Any = (object is [String: Any] || object is [Any]) ? object : ["value": object]
        return try PropertyListSerialization.data(fromPropertyList: rooted,
                                                  format: .xml,
                                                  options: 0)
    }

    static func encodeXML(_ value: DataValue) -> String {
        var output = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        output += element(named: "root", value: value, indent: 0)
        return output + "\n"
    }

    private static func element(named name: String, value: DataValue, indent: Int) -> String {
        let padding = String(repeating: "  ", count: indent)
        let tag = sanitizeTag(name)

        switch value {
        case .null:
            return "\(padding)<\(tag)/>"
        case .bool(let flag):
            return "\(padding)<\(tag)>\(flag ? "true" : "false")</\(tag)>"
        case .number(let num):
            return "\(padding)<\(tag)>\(formatNumber(num))</\(tag)>"
        case .string(let text):
            return "\(padding)<\(tag)>\(Markup.escapeXML(Markup.sanitizeXML(text)))</\(tag)>"
        case .array(let items):
            var lines = ["\(padding)<\(tag)>"]
            for item in items {
                lines.append(element(named: "item", value: item, indent: indent + 1))
            }
            lines.append("\(padding)</\(tag)>")
            return lines.joined(separator: "\n")
        case .object(let pairs):
            var lines = ["\(padding)<\(tag)>"]
            for pair in pairs {
                lines.append(element(named: pair.key, value: pair.value, indent: indent + 1))
            }
            lines.append("\(padding)</\(tag)>")
            return lines.joined(separator: "\n")
        }
    }

    private static func sanitizeTag(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isLetter || character.isNumber || character == "_" || character == "-" || character == "." {
                result.append(character)
            } else {
                result.append("_")
            }
        }
        if result.isEmpty { return "item" }
        if let first = result.first, first.isNumber { return "n" + result }
        return result
    }

    static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    // MARK: - CSV

    /// Builds an array-of-objects when the first row looks like a header,
    /// so CSV → JSON gives named fields instead of bare rows.
    static func rowsToValue(_ rows: [[String]]) -> DataValue {
        guard let header = rows.first else { return .array([]) }
        let body = rows.dropFirst()
        guard !body.isEmpty else {
            return .array(header.map { .string($0) })
        }

        var objects: [DataValue] = []
        for row in body {
            var pairs: [(key: String, value: DataValue)] = []
            for (index, key) in header.enumerated() {
                let cell = index < row.count ? row[index] : ""
                pairs.append((key: key.isEmpty ? "column\(index + 1)" : key, value: .string(cell)))
            }
            objects.append(.object(pairs))
        }
        return .array(objects)
    }

    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?
        var finished = false

        func nextCharacter() -> Character? {
            if let held = pending { pending = nil; return held }
            return iterator.next()
        }

        while let character = nextCharacter() {
            if inQuotes {
                if character == "\"" {
                    if let peek = nextCharacter() {
                        if peek == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = peek
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }

            switch character {
            case "\"":
                inQuotes = true
            case ",":
                row.append(field)
                field = ""
            case "\r":
                break
            case "\n":
                row.append(field)
                field = ""
                rows.append(row)
                row = []
            default:
                field.append(character)
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        // Drop a trailing empty row produced by a final newline.
        if let last = rows.last, last.count == 1, last[0].isEmpty {
            rows.removeLast()
        }
        return rows
    }

    static func encodeCSV(_ value: DataValue) -> String {
        let rows = csvRows(from: value)
        return rows.map { row in
            row.map(quoteCSVField).joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }

    private static func quoteCSVField(_ field: String) -> String {
        let needsQuoting = field.contains(",") || field.contains("\"")
            || field.contains("\n") || field.contains("\r")
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func csvRows(from value: DataValue) -> [[String]] {
        switch value {
        case .array(let items):
            // Array of objects → header row plus one row per object.
            if let firstItem = items.first, case .object(let first) = firstItem {
                let header = first.map(\.key)
                var rows: [[String]] = [header]
                for item in items {
                    guard case .object(let pairs) = item else { continue }
                    var row: [String] = []
                    for key in header {
                        let match = pairs.first { $0.key == key }?.value ?? .null
                        row.append(csvScalar(match))
                    }
                    rows.append(row)
                }
                return rows
            }
            // Array of arrays → straight through.
            if items.allSatisfy({ if case .array = $0 { return true } else { return false } }) {
                return items.map { item -> [String] in
                    guard case .array(let cells) = item else { return [] }
                    return cells.map(csvScalar)
                }
            }
            return [["value"]] + items.map { [csvScalar($0)] }

        case .object(let pairs):
            return [["key", "value"]] + pairs.map { [$0.key, csvScalar($0.value)] }

        default:
            return [["value"], [csvScalar(value)]]
        }
    }

    private static func csvScalar(_ value: DataValue) -> String {
        switch value {
        case .null:             return ""
        case .bool(let flag):   return flag ? "true" : "false"
        case .number(let num):  return formatNumber(num)
        case .string(let text): return text
        default:                return ""
        }
    }
}

// MARK: - XML → value

private final class XMLValueDelegate: NSObject, XMLParserDelegate {

    private final class Frame {
        let name: String
        var text = ""
        var children: [(key: String, value: DataValue)] = []
        init(name: String) { self.name = name }
    }

    private var stack: [Frame] = []
    var result: DataValue?

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let frame = Frame(name: elementName)
        for (key, value) in attributeDict.sorted(by: { $0.key < $1.key }) {
            frame.children.append((key: "@" + key, value: .string(value)))
        }
        stack.append(frame)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        guard let frame = stack.popLast() else { return }
        let value = build(frame)

        if let parent = stack.last {
            parent.children.append((key: frame.name, value: value))
        } else {
            result = .object([(key: frame.name, value: value)])
        }
    }

    private func build(_ frame: Frame) -> DataValue {
        let trimmed = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !frame.children.isEmpty else { return .string(trimmed) }

        var order: [String] = []
        var grouped: [String: [DataValue]] = [:]
        for child in frame.children {
            if grouped[child.key] == nil { order.append(child.key) }
            grouped[child.key, default: []].append(child.value)
        }

        var pairs: [(key: String, value: DataValue)] = []
        for key in order {
            let values = grouped[key] ?? []
            pairs.append((key: key, value: values.count == 1 ? values[0] : .array(values)))
        }
        if !trimmed.isEmpty {
            pairs.append((key: "#text", value: .string(trimmed)))
        }
        return .object(pairs)
    }
}
