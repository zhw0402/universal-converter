//
//  ZipKit.swift
//  万能转换
//
//  A dependency-free ZIP reader/writer. The document converters
//  (docx, epub) need to unpack OOXML/EPUB packages, and the archive
//  tools need to build new ones. Built on Apple's Compression
//  framework, whose COMPRESSION_ZLIB is raw DEFLATE — exactly the
//  payload a ZIP entry stores.
//

import Foundation
import Compression

// MARK: - Errors

enum ZipError: LocalizedError {
    case malformed
    case entryNotFound(String)
    case unsupportedMethod(UInt16)
    case inflateFailed

    var errorDescription: String? {
        switch self {
        case .malformed:
            return "压缩包已损坏或格式不受支持。"
        case .entryNotFound(let name):
            return "压缩包中找不到 \(name)。"
        case .unsupportedMethod(let method):
            return "不支持的压缩方式（\(method)）。"
        case .inflateFailed:
            return "解压失败。"
        }
    }
}

// MARK: - Raw DEFLATE

enum RawDeflate {

    /// Inflate a raw DEFLATE stream. `expectedSize` is only a capacity
    /// hint; the real size is discovered by growing the buffer.
    static func decompress(_ data: Data, expectedSize: Int = 0) -> Data? {
        if data.isEmpty { return Data() }
        if expectedSize == 0 { return Data() }

        var capacity = max(expectedSize + 64, 4096)
        var lastFull: Data?

        for _ in 0..<16 {
            var buffer = Data(count: capacity)
            let written = buffer.withUnsafeMutableBytes { dst -> Int in
                guard let out = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return data.withUnsafeBytes { src -> Int in
                    guard let input = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(out, capacity,
                                                     input, data.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 {
                buffer.count = written
                if written < capacity { return buffer }
                lastFull = buffer          // may be truncated — try a bigger buffer
            }
            capacity *= 2
        }
        return lastFull
    }

    /// Deflate a buffer. Returns nil when the result would not be
    /// smaller than the input, so callers can fall back to STORE.
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = max(data.count + data.count / 2 + 512, 4096)

        var buffer = Data(count: capacity)
        let written = buffer.withUnsafeMutableBytes { dst -> Int in
            guard let out = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { src -> Int in
                guard let input = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(out, capacity,
                                                 input, data.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < data.count else { return nil }
        buffer.count = written
        return buffer
    }
}

// MARK: - CRC-32

enum CRC32 {

    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        return table
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for byte in bytes {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Little-endian reading helpers

private extension Data {

    func le16(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let base = startIndex + offset
        return Int(self[base]) | (Int(self[base + 1]) << 8)
    }

    func le32(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let base = startIndex + offset
        return Int(self[base])
            | (Int(self[base + 1]) << 8)
            | (Int(self[base + 2]) << 16)
            | (Int(self[base + 3]) << 24)
    }

    func slice(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset + length <= count else { return nil }
        return self[(startIndex + offset)..<(startIndex + offset + length)]
    }
}

private func putLE16(_ value: Int, into data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
}

private func putLE32(_ value: Int, into data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 24) & 0xFF))
}

// MARK: - Reading

struct ZipEntry {
    let name: String
    let method: Int
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

struct ZipArchive {

    let entries: [ZipEntry]
    private let data: Data

    init(data: Data) throws {
        self.data = data

        // Locate the End Of Central Directory record by scanning backwards.
        let minimumEOCD = 22
        guard data.count >= minimumEOCD else { throw ZipError.malformed }

        var eocd = -1
        var cursor = data.count - minimumEOCD
        let floor = max(0, data.count - 66_000)
        while cursor >= floor {
            if data.le32(cursor) == 0x0605_4B50 { eocd = cursor; break }
            cursor -= 1
        }
        guard eocd >= 0 else { throw ZipError.malformed }

        guard let entryCount = data.le16(eocd + 10),
              let directoryOffset = data.le32(eocd + 16) else {
            throw ZipError.malformed
        }

        var parsed: [ZipEntry] = []
        var offset = directoryOffset

        for _ in 0..<entryCount {
            guard data.le32(offset) == 0x0201_4B50 else { break }
            guard let method = data.le16(offset + 10),
                  let compressed = data.le32(offset + 20),
                  let uncompressed = data.le32(offset + 24),
                  let nameLength = data.le16(offset + 28),
                  let extraLength = data.le16(offset + 30),
                  let commentLength = data.le16(offset + 32),
                  let localOffset = data.le32(offset + 42),
                  let nameData = data.slice(offset + 46, nameLength) else {
                throw ZipError.malformed
            }
            let name = String(data: nameData, encoding: .utf8)
                ?? String(decoding: nameData, as: UTF8.self)

            parsed.append(ZipEntry(name: name,
                                   method: method,
                                   compressedSize: compressed,
                                   uncompressedSize: uncompressed,
                                   localHeaderOffset: localOffset))

            offset += 46 + nameLength + extraLength + commentLength
        }

        self.entries = parsed
    }

    init(contentsOf url: URL) throws {
        let raw = try Data(contentsOf: url)
        try self.init(data: raw)
    }

    var names: [String] { entries.map(\.name) }

    func entry(named name: String) -> ZipEntry? {
        if let exact = entries.first(where: { $0.name == name }) { return exact }
        // Some writers prefix entries with "./" — be forgiving.
        return entries.first { $0.name.hasSuffix("/" + name) }
    }

    func contains(_ name: String) -> Bool { entry(named: name) != nil }

    /// Unpack one entry. STORE and DEFLATE are supported; anything else
    /// (bzip2, LZMA, …) is reported rather than silently mangled.
    func contents(of name: String) throws -> Data {
        guard let entry = entry(named: name) else { throw ZipError.entryNotFound(name) }
        return try contents(of: entry)
    }

    func contents(of entry: ZipEntry) throws -> Data {
        if entry.uncompressedSize == 0 { return Data() }

        guard let localNameLength = data.le16(entry.localHeaderOffset + 26),
              let localExtraLength = data.le16(entry.localHeaderOffset + 28) else {
            throw ZipError.malformed
        }
        let start = entry.localHeaderOffset + 30 + localNameLength + localExtraLength
        guard let payload = data.slice(start, entry.compressedSize) else {
            throw ZipError.malformed
        }

        switch entry.method {
        case 0:
            return payload
        case 8:
            guard let inflated = RawDeflate.decompress(payload,
                                                       expectedSize: entry.uncompressedSize) else {
                throw ZipError.inflateFailed
            }
            return inflated
        default:
            throw ZipError.unsupportedMethod(UInt16(entry.method))
        }
    }

    /// Every entry whose name ends with one of the given extensions,
    /// in archive order — used to find EPUB spine documents.
    func entries(withExtension ext: String) -> [ZipEntry] {
        let lowered = ext.lowercased()
        return entries.filter { $0.name.lowercased().hasSuffix("." + lowered) }
    }
}

// MARK: - Writing

struct ZipBuilder {

    private struct Record {
        let name: String
        let crc: UInt32
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let offset: Int
    }

    private var payload = Data()
    private var records: [Record] = []
    private var usedNames = Set<String>()

    private static let utf8Flag = 0x0800

    mutating func add(_ name: String, contents: Data, allowCompression: Bool = true) {
        var unique = name
        var suffix = 2
        while usedNames.contains(unique) {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            unique = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            suffix += 1
        }
        usedNames.insert(unique)

        let crc = CRC32.checksum(contents)
        var method = 0
        var body = contents

        if allowCompression, contents.count > 64, let deflated = RawDeflate.compress(contents) {
            method = 8
            body = deflated
        }

        let offset = payload.count
        let nameBytes = Data(unique.utf8)

        putLE32(0x0403_4B50, into: &payload)      // local file header
        putLE16(20, into: &payload)               // version needed
        putLE16(Self.utf8Flag, into: &payload)    // general purpose flags
        putLE16(method, into: &payload)
        putLE16(0, into: &payload)                // mod time
        putLE16(0, into: &payload)                // mod date
        putLE32(Int(crc), into: &payload)
        putLE32(body.count, into: &payload)
        putLE32(contents.count, into: &payload)
        putLE16(nameBytes.count, into: &payload)
        putLE16(0, into: &payload)                // extra field length
        payload.append(nameBytes)
        payload.append(body)

        records.append(Record(name: unique,
                              crc: crc,
                              method: method,
                              compressedSize: body.count,
                              uncompressedSize: contents.count,
                              offset: offset))
    }

    mutating func add(_ name: String, text: String, allowCompression: Bool = true) {
        add(name, contents: Data(text.utf8), allowCompression: allowCompression)
    }

    func finalized() -> Data {
        var archive = payload
        let directoryOffset = archive.count

        for record in records {
            let nameBytes = Data(record.name.utf8)
            putLE32(0x0201_4B50, into: &archive)
            putLE16(20, into: &archive)               // version made by
            putLE16(20, into: &archive)               // version needed
            putLE16(Self.utf8Flag, into: &archive)
            putLE16(record.method, into: &archive)
            putLE16(0, into: &archive)
            putLE16(0, into: &archive)
            putLE32(Int(record.crc), into: &archive)
            putLE32(record.compressedSize, into: &archive)
            putLE32(record.uncompressedSize, into: &archive)
            putLE16(nameBytes.count, into: &archive)
            putLE16(0, into: &archive)                // extra
            putLE16(0, into: &archive)                // comment
            putLE16(0, into: &archive)                // disk number
            putLE16(0, into: &archive)                // internal attributes
            putLE32(0, into: &archive)                // external attributes
            putLE32(record.offset, into: &archive)
            archive.append(nameBytes)
        }

        let directorySize = archive.count - directoryOffset

        putLE32(0x0605_4B50, into: &archive)
        putLE16(0, into: &archive)                    // this disk
        putLE16(0, into: &archive)                    // disk with directory
        putLE16(records.count, into: &archive)
        putLE16(records.count, into: &archive)
        putLE32(directorySize, into: &archive)
        putLE32(directoryOffset, into: &archive)
        putLE16(0, into: &archive)                    // comment length

        return archive
    }
}
