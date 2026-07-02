import Compression
import Foundation

/// A minimal read-only ZIP archive, enough for EPUB and DOCX files: parses the central
/// directory and inflates stored (0) or deflated (8) entries with the system Compression
/// framework. No third-party dependency needed.
nonisolated struct ZipArchive {

    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    let entries: [Entry]
    private let data: Data

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        self.data = data
        // Find the End Of Central Directory record (scan backwards over the trailing comment).
        let eocdSig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let scanStart = max(0, data.count - 66_000)
        var eocd = -1
        if data.count >= 22 {
            var i = data.count - 22
            while i >= scanStart {
                if data[i] == eocdSig[0], data[i + 1] == eocdSig[1],
                   data[i + 2] == eocdSig[2], data[i + 3] == eocdSig[3] {
                    eocd = i
                    break
                }
                i -= 1
            }
        }
        guard eocd >= 0 else { return nil }

        let total = Int(Self.u16(data, eocd + 10))
        let cdOffset = Int(Self.u32(data, eocd + 16))
        var entries: [Entry] = []
        var p = cdOffset
        for _ in 0..<total {
            guard p + 46 <= data.count, Self.u32(data, p) == 0x0201_4B50 else { break }
            let method = Self.u16(data, p + 10)
            let compressedSize = Int(Self.u32(data, p + 20))
            let uncompressedSize = Int(Self.u32(data, p + 24))
            let nameLen = Int(Self.u16(data, p + 28))
            let extraLen = Int(Self.u16(data, p + 30))
            let commentLen = Int(Self.u16(data, p + 32))
            let localOffset = Int(Self.u32(data, p + 42))
            guard p + 46 + nameLen <= data.count else { break }
            let nameData = data.subdata(in: (p + 46)..<(p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""
            entries.append(Entry(
                name: name, method: method,
                compressedSize: compressedSize, uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset
            ))
            p += 46 + nameLen + extraLen + commentLen
        }
        guard !entries.isEmpty else { return nil }
        self.entries = entries
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    func extract(_ entry: Entry) -> Data? {
        let p = entry.localHeaderOffset
        guard p + 30 <= data.count, Self.u32(data, p) == 0x0403_4B50 else { return nil }
        // The local header repeats name/extra with its own lengths; the data follows them.
        let nameLen = Int(Self.u16(data, p + 26))
        let extraLen = Int(Self.u16(data, p + 28))
        let start = p + 30 + nameLen + extraLen
        guard start + entry.compressedSize <= data.count else { return nil }
        let raw = data.subdata(in: start..<(start + entry.compressedSize))

        switch entry.method {
        case 0:
            return raw
        case 8:
            return Self.inflate(raw, expectedSize: entry.uncompressedSize)
        default:
            return nil
        }
    }

    func extract(named name: String) -> Data? {
        entry(named: name).flatMap(extract)
    }

    /// Raw DEFLATE, which is what COMPRESSION_ZLIB means in the Compression framework.
    private static func inflate(_ input: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstPtr = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstPtr, expectedSize, srcPtr, input.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        output.removeSubrange(written..<output.count)
        return output
    }

    private static func u16(_ d: Data, _ i: Int) -> UInt16 {
        UInt16(d[i]) | (UInt16(d[i + 1]) << 8)
    }

    private static func u32(_ d: Data, _ i: Int) -> UInt32 {
        UInt32(d[i]) | (UInt32(d[i + 1]) << 8) | (UInt32(d[i + 2]) << 16) | (UInt32(d[i + 3]) << 24)
    }
}
