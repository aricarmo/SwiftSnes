//  OnlineProtocol.swift
//  O que anfitrião e convidados trocam numa sessão online: código da sala,
//  estado da sala (quem está em cada controle), mensagens de controle em JSON
//  e o enquadramento binário de vídeo, áudio e entrada.

import Foundation

enum SessionCode {
    /// Sem 0/O/1/I: o código é lido em voz alta e digitado à mão.
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    static let length = 6
    /// Serviço Bonjour anunciado pelo anfitrião na rede local.
    static let serviceType = "_notchsnes._tcp"
    /// Versão do protocolo: anfitrião e convidado precisam concordar.
    static let protocolVersion = 1

    static func generate() -> String {
        String((0..<length).map { _ in alphabet.randomElement()! })
    }

    /// Maiúsculas, só letras e dígitos: aceita "7fk-3qm" e "7FK 3QM".
    static func normalize(_ text: String) -> String {
        String(text.uppercased().filter { alphabet.contains($0) }.prefix(length))
    }

    static func isComplete(_ code: String) -> Bool { code.count == length }

    /// "7FK3QM" → "7FK-3QM".
    static func display(_ code: String) -> String {
        guard code.count == length else { return code }
        let mid = code.index(code.startIndex, offsetBy: length / 2)
        return "\(code[..<mid])-\(code[mid...])"
    }

    static func serviceName(for code: String) -> String { "NotchSnes \(code)" }
}

/// Alguém na sala: o anfitrião, um jogador ou um espectador.
struct Participant: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    /// Ida e volta até o anfitrião, medida por ele. Nulo para o próprio anfitrião.
    var latencyMs: Int?
}

/// Estado da sala como o anfitrião o vê; vai inteiro para os convidados a cada mudança.
struct RoomState: Codable, Equatable {
    static let slotCount = 4

    var code: String
    var hostName: String
    var gameTitle: String
    /// Um por controle do SNES; o 0 é sempre o anfitrião.
    var slots: [Participant?]
    var spectators: [Participant]
    /// Anfitrião trancou: ninguém pega controle livre.
    var locked: Bool

    init(code: String, hostName: String, gameTitle: String, host: Participant) {
        self.code = code
        self.hostName = hostName
        self.gameTitle = gameTitle
        slots = [host, nil, nil, nil]
        spectators = []
        locked = false
    }

    /// Todo mundo menos o anfitrião.
    var onlineCount: Int {
        slots.dropFirst().compactMap { $0 }.count + spectators.count
    }

    func slot(of id: UUID) -> Int? {
        slots.firstIndex { $0?.id == id }
    }

    func participant(_ id: UUID) -> Participant? {
        slots.compactMap { $0 }.first { $0.id == id } ?? spectators.first { $0.id == id }
    }

    var freeSlots: [Int] {
        (1..<Self.slotCount).filter { slots[$0] == nil }
    }
}

/// Mensagens de controle, em JSON dentro de um quadro `.control`.
enum ControlMessage: Codable {
    // Convidado → anfitrião
    case hello(name: String, version: Int)
    case takeSlot(Int)
    case releaseSlot
    case rename(String)
    // Anfitrião → convidado
    case welcome(id: UUID, room: RoomState)
    case room(RoomState)
    case notice(String)
    /// Recusado ou removido; a conexão fecha em seguida.
    case rejected(String)
    case ended
}

/// Tipos de quadro no fio. Tudo vai numa única conexão TCP, na ordem:
/// `[tipo u8][tamanho u32 BE][payload]`.
enum WireType: UInt8 {
    case control = 0
    /// `[frame u32][flags u8][keyframe: sps u16+bytes, pps u16+bytes][NALs AVCC]`
    case video = 1
    /// `[amostras u16][L0 R0 L1 R1 … Int16 LE]` a 32 kHz.
    case audio = 2
    /// `[slot u8][máscara u16]`, no formato de $4218.
    case input = 3
    /// `[nanos u64]` — devolvido tal qual num `.pong`.
    case ping = 4
    case pong = 5
}

struct WireMessage {
    let type: WireType
    let payload: Data

    static let headerSize = 5
    /// Nada legítimo passa disso; protege contra um cabeçalho corrompido.
    static let maxPayload = 4 << 20

    func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.append(type.rawValue)
        data.appendU32(UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func control(_ message: ControlMessage) -> WireMessage? {
        guard let json = try? JSONEncoder().encode(message) else { return nil }
        return WireMessage(type: .control, payload: json)
    }

    func controlMessage() -> ControlMessage? {
        guard type == .control else { return nil }
        return try? JSONDecoder().decode(ControlMessage.self, from: payload)
    }

    static func input(slot: Int, mask: UInt16) -> WireMessage {
        var data = Data(capacity: 3)
        data.append(UInt8(slot))
        data.appendU16(mask)
        return WireMessage(type: .input, payload: data)
    }

    static func audio(left: [Int16], right: [Int16]) -> WireMessage {
        let count = min(left.count, right.count)
        var data = Data(capacity: 2 + count * 4)
        data.appendU16(UInt16(count))
        var interleaved = [Int16](repeating: 0, count: count * 2)
        for i in 0..<count {
            interleaved[i * 2] = left[i]
            interleaved[i * 2 + 1] = right[i]
        }
        interleaved.withUnsafeBytes { data.append(contentsOf: $0) }
        return WireMessage(type: .audio, payload: data)
    }

    static func ping(nanos: UInt64 = DispatchTime.now().uptimeNanoseconds) -> WireMessage {
        var data = Data(capacity: 8)
        data.appendU64(nanos)
        return WireMessage(type: .ping, payload: data)
    }
}

// MARK: - Bytes

extension Data {
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value >> 8)); append(UInt8(value & 0xFF))
    }

    mutating func appendU32(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }

    mutating func appendU64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { append(UInt8((value >> UInt64(shift)) & 0xFF)) }
    }
}

/// Leitura sequencial big-endian; `nil` quando acaba antes do esperado.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Int { bytes.count - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() -> UInt16? {
        guard let hi = u8(), let lo = u8() else { return nil }
        return UInt16(hi) << 8 | UInt16(lo)
    }

    mutating func u32() -> UInt32? {
        guard let hi = u16(), let lo = u16() else { return nil }
        return UInt32(hi) << 16 | UInt32(lo)
    }

    mutating func u64() -> UInt64? {
        guard let hi = u32(), let lo = u32() else { return nil }
        return UInt64(hi) << 32 | UInt64(lo)
    }

    mutating func bytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func rest() -> [UInt8] {
        defer { offset = bytes.count }
        return Array(bytes[offset...])
    }
}
