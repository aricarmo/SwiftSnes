//  SaveState.swift
//  Serialização binária do estado do console. Cada componente escreve seus
//  campos numa ordem fixa; nada de Codable/JSON (lento e dezenas de vezes maior).

import Foundation

struct StateWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 320 * 1024) {
        bytes.reserveCapacity(capacity)
    }

    mutating func put(_ v: UInt8) { bytes.append(v) }
    mutating func put(_ v: Bool) { bytes.append(v ? 1 : 0) }
    mutating func put(_ v: UInt16) { putFixed(v) }
    mutating func put(_ v: UInt32) { putFixed(v) }
    mutating func put(_ v: UInt64) { putFixed(v) }
    mutating func put(_ v: Int16) { putFixed(UInt16(bitPattern: v)) }
    mutating func put(_ v: Int32) { putFixed(UInt32(bitPattern: v)) }
    mutating func put(_ v: Int) { putFixed(UInt64(bitPattern: Int64(v))) }
    mutating func put(_ v: Double) { putFixed(v.bitPattern) }

    mutating func put(_ v: [UInt8]) {
        put(UInt32(v.count))
        bytes.append(contentsOf: v)
    }
    mutating func put(_ v: [Bool]) { put(UInt32(v.count)); for x in v { put(x) } }
    mutating func put(_ v: [UInt16]) { put(UInt32(v.count)); for x in v { put(x) } }
    mutating func put(_ v: [Int16]) { put(UInt32(v.count)); for x in v { put(x) } }
    mutating func put(_ v: [Int]) { put(UInt32(v.count)); for x in v { put(x) } }
    mutating func put(_ v: String) { put(Array(v.utf8)) }

    private mutating func putFixed<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
    }
}

struct StateReader {
    enum Error: Swift.Error { case truncated, badMagic, badVersion, romMismatch, sizeMismatch }

    private let bytes: [UInt8]
    private var pos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { pos >= bytes.count }

    mutating func u8() throws -> UInt8 {
        guard pos < bytes.count else { throw Error.truncated }
        defer { pos += 1 }
        return bytes[pos]
    }
    mutating func bool() throws -> Bool { try u8() != 0 }
    mutating func u16() throws -> UInt16 { try fixed() }
    mutating func u32() throws -> UInt32 { try fixed() }
    mutating func u64() throws -> UInt64 { try fixed() }
    mutating func i16() throws -> Int16 { Int16(bitPattern: try fixed()) }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try fixed()) }
    mutating func int() throws -> Int { Int(Int64(bitPattern: try fixed())) }
    mutating func double() throws -> Double { Double(bitPattern: try fixed()) }

    mutating func bytes8() throws -> [UInt8] {
        let n = Int(try u32())
        guard pos + n <= bytes.count else { throw Error.truncated }
        defer { pos += n }
        return Array(bytes[pos..<pos + n])
    }
    /// Mesmo tamanho do destino, senão o layout do arquivo não é o esperado.
    mutating func bytes8(count: Int) throws -> [UInt8] {
        let v = try bytes8()
        guard v.count == count else { throw Error.sizeMismatch }
        return v
    }
    mutating func bools() throws -> [Bool] { let n = Int(try u32()); return try (0..<n).map { _ in try bool() } }
    mutating func u16s() throws -> [UInt16] { let n = Int(try u32()); return try (0..<n).map { _ in try u16() } }
    mutating func i16s() throws -> [Int16] { let n = Int(try u32()); return try (0..<n).map { _ in try i16() } }
    mutating func ints() throws -> [Int] { let n = Int(try u32()); return try (0..<n).map { _ in try int() } }
    mutating func string() throws -> String { String(decoding: try bytes8(), as: UTF8.self) }

    private mutating func fixed<T: FixedWidthInteger>() throws -> T {
        let n = MemoryLayout<T>.size
        guard pos + n <= bytes.count else { throw Error.truncated }
        var v: T = 0
        withUnsafeMutableBytes(of: &v) { dst in
            for i in 0..<n { dst[i] = bytes[pos + i] }
        }
        pos += n
        return T(littleEndian: v)
    }
}
