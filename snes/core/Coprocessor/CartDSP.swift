// SNES cartridge DSP (NEC uPD77C25 + DSP-1/1B/2/3/4 mask ROM).
// Protocol and firmware layout follow gufranco/snes-dsp-python (MIT).
// Firmware is not bundled; drop SNES_dsp1b.rom (etc.) in
// ~/Library/Application Support/NotchSnes/bios (see userFirmwareDirectory).

import CryptoKit
import Foundation

enum CartDSPPart: String, CaseIterable {
    case dsp1, dsp1a, dsp1b, dsp2, dsp3, dsp4

    var imageName: String {
        self == .dsp1a ? CartDSPPart.dsp1.rawValue : rawValue
    }

    var fallbacks: [CartDSPPart] {
        switch self {
        case .dsp1a, .dsp1b: return [.dsp1]
        case .dsp1: return [.dsp1b]
        default: return []
        }
    }
}

struct CartDSPIdentity {
    let part: CartDSPPart
    let programWords: Int
    let dataWords: Int

    var programBytes: Int { programWords * 3 }
    var dataBytes: Int { dataWords * 2 }
    var totalBytes: Int { programBytes + dataBytes }
}

enum CartDSPFirmware {
    static let bootSteps = 20_000
    static let settleLimit = 400_000
    static let dspClock = 7_600_000
    static let masterClock = 21_477_272

    private static let known: [String: CartDSPIdentity] = [
        "5f2e5ed06b362be023b978b5978813ecb9a07c76592454b45c2a1ed17a0de349":
            CartDSPIdentity(part: .dsp1, programWords: 2048, dataWords: 1024),
        "4d42db0f36faef263d6b93f508e8c1c4ae8fc2605fd35e3390ecc02905cd420c":
            CartDSPIdentity(part: .dsp1b, programWords: 2048, dataWords: 1024),
        "5efbdf96ed0652790855225964f3e90e6a4d466cfa64df25b110933c6cf94ea1":
            CartDSPIdentity(part: .dsp2, programWords: 2048, dataWords: 1024),
        "2e635f72e4d4681148bc35429421c9b946e4f407590e74e31b93b8987b63ba90":
            CartDSPIdentity(part: .dsp3, programWords: 2048, dataWords: 1024),
        "63ede17322541c191ed1fdf683872554a0a57306496afc43c59de7c01a6e764a":
            CartDSPIdentity(part: .dsp4, programWords: 2048, dataWords: 1024),
    ]

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func identify(_ data: Data) -> (CartDSPIdentity, Data)? {
        for candidate in expansions(data) {
            if let identity = known[sha256Hex(candidate)] { return (identity, candidate) }
        }
        return nil
    }

    /// Dumps from ares/retrobios store each program word and table word little-endian.
    private static func expansions(_ data: Data) -> [Data] {
        var out = [data]
        if data.count > 512 {
            out.append(Data(data.dropFirst(512)))
            out.append(Data(data.dropLast(512)))
        }
        if data.count >= 2, data.count % 2 == 0 {
            var swapped = Data(count: data.count)
            swapped.withUnsafeMutableBytes { dest in
                data.withUnsafeBytes { src in
                    let from = src.bindMemory(to: UInt8.self)
                    let to = dest.bindMemory(to: UInt8.self)
                    for i in stride(from: 0, to: data.count, by: 2) {
                        to[i] = from[i + 1]
                        to[i + 1] = from[i]
                    }
                }
            }
            out.append(swapped)
        }
        if data.count == 8192 {
            out.append(swapDSPWords(data))
        }
        return out
    }

    private static func swapDSPWords(_ data: Data) -> Data {
        var converted = Data(count: data.count)
        converted.withUnsafeMutableBytes { dest in
            data.withUnsafeBytes { src in
                let from = src.bindMemory(to: UInt8.self)
                let to = dest.bindMemory(to: UInt8.self)
                for i in stride(from: 0, to: 6144, by: 3) {
                    to[i] = from[i + 2]
                    to[i + 1] = from[i + 1]
                    to[i + 2] = from[i]
                }
                for i in stride(from: 6144, to: 8192, by: 2) {
                    to[i] = from[i + 1]
                    to[i + 1] = from[i]
                }
            }
        }
        return converted
    }

    static func load(wanted: CartDSPPart, extraDirectories: [URL] = []) -> (CartDSPIdentity, Data)? {
        var found: [CartDSPPart: (CartDSPIdentity, Data)] = [:]
        for directory in searchDirectories(extra: extraDirectories) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }
            for url in files {
                let ext = url.pathExtension.lowercased()
                let name = url.lastPathComponent.lowercased()
                let looksLikeFirmware = ext == "bin" || ext == "rom" || name.contains("dsp1") || name.contains("dsp2")
                    || name.contains("dsp3") || name.contains("dsp4")
                guard looksLikeFirmware else { continue }
                guard let data = try? Data(contentsOf: url) else { continue }
                guard let (identity, image) = identify(data) else {
                    if data.count == 8192 || data.count == 8192 + 512 {
                        Log.dsp.notice("ignorado \(url.lastPathComponent, privacy: .public) (\(data.count) bytes, sha256 \(sha256Hex(data).prefix(12), privacy: .public)…)")
                    }
                    continue
                }
                if found[identity.part] == nil {
                    found[identity.part] = (identity, image)
                    Log.dsp.info("firmware \(identity.part.rawValue, privacy: .public) ← \(url.path, privacy: .public)")
                }
            }
        }
        if let match = found[wanted] { return match }
        if wanted.imageName != wanted.rawValue,
           let shared = CartDSPPart(rawValue: wanted.imageName),
           let match = found[shared] {
            return match
        }
        for fallback in wanted.fallbacks {
            if let match = found[fallback] { return match }
        }
        return nil
    }

    static func userFirmwareDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("NotchSnes/bios", isDirectory: true)
    }

    static func searchDirectories(extra: [URL]) -> [URL] {
        var urls: [URL] = extra
        let env = ProcessInfo.processInfo.environment
        for key in ["SNES_DSP_FIRMWARE_DIR", "UPD7725_FIRMWARE_DIR"] {
            if let value = env[key] {
                urls += value.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            }
        }
        urls.append(userFirmwareDirectory())
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(support.appendingPathComponent("NotchSnes/firmware", isDirectory: true))
            urls.append(support.appendingPathComponent("SwiftSnes/bios", isDirectory: true))  // nome antigo
            for emulator in ["ares/Firmware", "bsnes/Firmware", "higan/Firmware", "Snes9x"] {
                urls.append(support.appendingPathComponent(emulator, isDirectory: true))
            }
        }
        if let resources = Bundle.main.resourceURL {
            urls.append(resources.appendingPathComponent("bios", isDirectory: true))
            urls.append(resources)
        }
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.path
            if seen.contains(path) { return false }
            seen.insert(path)
            return FileManager.default.fileExists(atPath: path)
        }
    }

    static func part(forTitle title: String) -> CartDSPPart {
        let folded = title.uppercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: "")
        if folded.contains("DUNGEON MASTER") { return .dsp2 }
        if folded.contains("SD GUNDAM") { return .dsp3 }
        if folded.contains("TOP GEAR 3000") || folded.contains("PLANETS CHAMP") { return .dsp4 }
        if folded.contains("PILOTWINGS") { return .dsp1 }
        return .dsp1b
    }
}

final class CartDSPChip {
    let part: CartDSPPart
    let core: UPD7725
    private var rest = 0

    init(part: CartDSPPart, image: Data, identity: CartDSPIdentity) {
        self.part = part
        core = UPD7725()
        let split = identity.programBytes
        core.loadFirmware(
            programBytes: image.prefix(split),
            tableBytes: image.suffix(from: split).prefix(identity.dataBytes)
        )
        boot()
    }

    func boot() {
        core.reset()
        for _ in 0..<CartDSPFirmware.settleLimit where !core.asking {
            core.step()
        }
    }

    func advance(cpuCycles: Int) {
        rest += cpuCycles * 8 * CartDSPFirmware.dspClock
        let steps = rest / CartDSPFirmware.masterClock
        rest %= CartDSPFirmware.masterClock
        if steps > 0 { core.run(steps: steps) }
    }

    func serialize(into w: inout StateWriter) {
        w.put(rest)
        core.serialize(into: &w)
    }

    func deserialize(from r: inout StateReader) throws {
        rest = try r.int()
        try core.deserialize(from: &r)
    }

    func read(isStatus: Bool) -> UInt8 {
        if isStatus { return core.readStatus() }
        return core.readData()
    }

    func write(_ value: UInt8, isStatus: Bool) {
        if isStatus { return }
        core.writeData(value)
    }

    /// A janela do DSP depende do layout do cartucho. Ela NÃO pode ser um
    /// catch-all: num jogo HiROM os bancos $20–$3F e $C0–$FF acima de $8000 são
    /// ROM, e reivindicá-los aqui sombreia metade do cartucho.
    ///
    /// - HiROM (Super Mario Kart): DR em $00–$1F:$6000–$6FFF, SR em $7000–$7FFF
    /// - LoROM (Pilotwings):       DR em $30–$3F:$8000–$BFFF, SR em $C000–$FFFF
    ///
    /// Retorna nil fora da janela, true para o registrador de status.
    static func port(bank: UInt32, offset: UInt32, mapper: Cartridge.Mapper) -> Bool? {
        let b = bank & 0x7F

        switch mapper {
        case .hiROM, .exHiROM:
            guard b <= 0x1F, offset >= 0x6000, offset < 0x8000 else { return nil }
            return offset >= 0x7000

        case .loROM:
            guard b >= 0x30, b <= 0x3F, offset >= 0x8000 else { return nil }
            return offset >= 0xC000
        }
    }
}
