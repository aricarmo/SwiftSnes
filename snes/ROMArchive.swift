import Foundation
import Compression

/// Lê a ROM de dentro de um `.zip` sem extrair para disco.
/// Só o necessário: diretório central, entradas `stored` (0) e `deflate` (8).
enum ROMArchive {
    struct Entry {
        let name: String
        let data: Data
    }

    enum ArchiveError: LocalizedError {
        case notAZip
        case noROMInside
        case unsupportedMethod(UInt16)
        case corrupt

        var errorDescription: String? {
            switch self {
            case .notAZip: return String(localized: "The file is not a valid zip")
            case .noROMInside: return String(localized: "No SNES ROM (.sfc/.smc) inside the zip")
            case .unsupportedMethod(let m): return String(localized: "Unsupported zip compression (method \(m))")
            case .corrupt: return String(localized: "Corrupt zip")
            }
        }
    }

    static let romExtensions: Set<String> = ["sfc", "smc", "fig", "swc"]

    static func isZip(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip"
    }

    /// Primeira entrada com extensão de ROM (a maior, se houver várias).
    static func extractROM(from zip: Data) throws -> Entry {
        let entries = try centralDirectory(zip)
        let candidates = entries.filter {
            romExtensions.contains(($0.name as NSString).pathExtension.lowercased())
        }
        guard let best = candidates.max(by: { $0.uncompressedSize < $1.uncompressedSize }) else {
            throw ArchiveError.noROMInside
        }
        return Entry(name: (best.name as NSString).lastPathComponent, data: try inflate(best, in: zip))
    }

    // MARK: - Formato

    private struct Header {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private static func centralDirectory(_ zip: Data) throws -> [Header] {
        let bytes = [UInt8](zip)
        guard bytes.count >= 22 else { throw ArchiveError.notAZip }

        // End of central directory: assinatura 0x06054b50, procura de trás (comentário até 64 KiB).
        var eocd = -1
        var i = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 0xFFFF)
        while i >= floor {
            if u32(bytes, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ArchiveError.notAZip }

        let count = Int(u16(bytes, eocd + 10))
        var offset = Int(u32(bytes, eocd + 16))
        var headers: [Header] = []
        headers.reserveCapacity(count)

        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(bytes, offset) == 0x0201_4B50 else { throw ArchiveError.corrupt }
            let method = u16(bytes, offset + 10)
            let compressed = Int(u32(bytes, offset + 20))
            let uncompressed = Int(u32(bytes, offset + 24))
            let nameLen = Int(u16(bytes, offset + 28))
            let extraLen = Int(u16(bytes, offset + 30))
            let commentLen = Int(u16(bytes, offset + 32))
            let local = Int(u32(bytes, offset + 42))
            guard offset + 46 + nameLen <= bytes.count else { throw ArchiveError.corrupt }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLen)], as: UTF8.self)
            headers.append(Header(name: name, method: method, compressedSize: compressed,
                                  uncompressedSize: uncompressed, localHeaderOffset: local))
            offset += 46 + nameLen + extraLen + commentLen
        }
        return headers
    }

    private static func inflate(_ h: Header, in zip: Data) throws -> Data {
        let bytes = [UInt8](zip)
        let lo = h.localHeaderOffset
        guard lo + 30 <= bytes.count, u32(bytes, lo) == 0x0403_4B50 else { throw ArchiveError.corrupt }
        // Tamanhos do cabeçalho local podem estar zerados (data descriptor); o diretório central é a fonte.
        let nameLen = Int(u16(bytes, lo + 26))
        let extraLen = Int(u16(bytes, lo + 28))
        let start = lo + 30 + nameLen + extraLen
        guard start + h.compressedSize <= bytes.count else { throw ArchiveError.corrupt }
        let payload = zip.subdata(in: start..<(start + h.compressedSize))

        switch h.method {
        case 0:
            return payload
        case 8:
            let capacity = max(h.uncompressedSize, 1)
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst -> Int in
                payload.withUnsafeBytes { src -> Int in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              src.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                                              nil, COMPRESSION_ZLIB) // ZLIB aqui = deflate cru, como no zip
                }
            }
            guard written == h.uncompressedSize else { throw ArchiveError.corrupt }
            return out
        default:
            throw ArchiveError.unsupportedMethod(h.method)
        }
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
