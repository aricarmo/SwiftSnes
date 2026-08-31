//
//  Cartridge.swift
//  snes
//
//  Detecção de header e mapeamento de ROM (LoROM / HiROM / ExHiROM).
//

import CryptoKit
import Foundation

final class Cartridge {

    enum Mapper {
        case loROM
        case hiROM
        case exHiROM

        var description: String {
            switch self {
            case .loROM:   return "LoROM"
            case .hiROM:   return "HiROM"
            case .exHiROM: return "ExHiROM"
            }
        }
    }

    private(set) var rom: [UInt8] = []
    private(set) var sram: [UInt8] = []
    private(set) var mapper: Mapper = .loROM
    private(set) var title: String = ""
    private(set) var fastROM: Bool = false
    private(set) var loaded: Bool = false
    /// SRAM alterada desde o último `markSRAMClean()`: só então vale gravar o .srm.
    private(set) var sramDirty: Bool = false
    /// SHA-256 da ROM (sem header SMC). Identifica o save independente do nome do arquivo.
    private(set) var romHash: String = ""
    /// Máscara para ROMs com tamanho potência de 2 (quase todas); evita o `%` no caminho quente.
    private var romMask: Int = 0

    /// Cartucho com coprocessador DSP-1/2/3/4 (µPD77C25).
    private(set) var hasDSP: Bool = false
    private(set) var dspPart: CartDSPPart = .dsp1b

    // Offset do header dentro da ROM
    private(set) var headerOffset: Int = 0x7FC0

    // MARK: - Carregamento

    func load(data: Data) throws {
        var bytes = [UInt8](data)

        // Remove header SMC de 512 bytes se presente
        if bytes.count % 0x8000 == 512 {
            bytes.removeFirst(512)
        }

        guard bytes.count >= 0x8000 else { throw EmulatorError.invalidROM }

        rom = bytes
        romMask = bytes.count & (bytes.count - 1) == 0 ? bytes.count - 1 : 0
        romHash = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()

        // Testa cada candidato e escolhe o de maior pontuação
        let candidates: [(Int, Mapper)] = [
            (0x007FC0, .loROM),
            (0x00FFC0, .hiROM),
            (0x40FFC0, .exHiROM)
        ]

        var best = (score: -1, offset: 0x7FC0, mapper: Mapper.loROM)
        for (offset, mode) in candidates {
            let s = score(at: offset, mapper: mode)
            if s > best.score {
                best = (s, offset, mode)
            }
        }

        headerOffset = best.offset
        mapper = best.mapper

        // Título (21 bytes ASCII)
        let titleBytes = readHeader(best.offset, count: 21)
        title = String(bytes: titleBytes.filter { $0 >= 0x20 && $0 < 0x7F }, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? "?"

        let mapMode = headerByte(best.offset + 0x15)
        fastROM = (mapMode & 0x10) != 0

        let cartType = headerByte(best.offset + 0x16)
        let extra = cartType & 0x0F
        hasDSP = (extra == 0x03 || extra == 0x04 || extra == 0x05)
        dspPart = CartDSPFirmware.part(forTitle: title)

        // SRAM: tamanho = 1 << n KB. Header com 0 = cartucho SEM SRAM, e isso
        // precisa ser respeitado: rotinas anti-pirataria escrevem na área de
        // SRAM e, se lerem de volta o que escreveram, sabotam o gameplay.
        // Em cartucho real a leitura volta open bus.
        let sramSizeCode = headerByte(best.offset + 0x18)
        let sramSize = sramSizeCode > 0 && sramSizeCode <= 0x0C ? (1 << Int(sramSizeCode)) * 1024 : 0
        sram = [UInt8](repeating: 0, count: sramSize)
        sramDirty = false

        loaded = true

        Log.cart.info("\(self.title, privacy: .public) | \(self.mapper.description, privacy: .public)\(self.fastROM ? " FastROM" : "", privacy: .public)\(self.hasDSP ? " + DSP" : "", privacy: .public) | ROM \(self.rom.count / 1024)KB | SRAM \(sramSize / 1024)KB | reset $\(String(format: "%04X", self.resetVector), privacy: .public)")
        if hasDSP {
            Log.cart.info("coprocessor \(self.dspPart.rawValue, privacy: .public) (NEC uPD77C25)")
        }
    }

    // MARK: - Heurística de detecção

    private func headerByte(_ absolute: Int) -> UInt8 {
        return absolute < rom.count ? rom[absolute] : 0
    }

    private func readHeader(_ offset: Int, count: Int) -> [UInt8] {
        guard offset + count <= rom.count else { return [] }
        return Array(rom[offset..<(offset + count)])
    }

    private func score(at offset: Int, mapper: Mapper) -> Int {
        guard offset + 0x20 <= rom.count else { return -1 }

        var points = 0

        // Map mode deve bater com o layout esperado
        let mapMode = headerByte(offset + 0x15) & 0x2F
        switch mapper {
        case .loROM   where mapMode == 0x20 || mapMode == 0x22: points += 8
        case .hiROM   where mapMode == 0x21: points += 8
        case .exHiROM where mapMode == 0x25: points += 8
        default: break
        }

        // Checksum + complemento devem somar $FFFF
        let checksum = UInt16(headerByte(offset + 0x1E)) | (UInt16(headerByte(offset + 0x1F)) << 8)
        let complement = UInt16(headerByte(offset + 0x1C)) | (UInt16(headerByte(offset + 0x1D)) << 8)
        if checksum ^ complement == 0xFFFF && checksum != 0 { points += 8 }

        // Vetor de reset tem que apontar para a área de ROM
        let reset = UInt16(headerByte(offset + 0x3C)) | (UInt16(headerByte(offset + 0x3D)) << 8)
        if reset >= 0x8000 { points += 4 } else { points -= 4 }

        // Título legível
        let titleBytes = readHeader(offset, count: 21)
        let printable = titleBytes.filter { ($0 >= 0x20 && $0 < 0x7F) }.count
        if printable >= 18 { points += 3 }

        // Tamanho declarado coerente
        let romSizeCode = headerByte(offset + 0x17)
        if romSizeCode >= 0x08 && romSizeCode <= 0x0D { points += 2 }

        return points
    }

    var resetVector: UInt16 {
        return UInt16(headerByte(headerOffset + 0x3C)) | (UInt16(headerByte(headerOffset + 0x3D)) << 8)
    }

    // MARK: - Mapeamento

    /// Traduz endereço de CPU em índice de ROM. Retorna nil se não for área de ROM.
    @inline(__always)
    func romIndex(bank: UInt32, offset: UInt32) -> Int? {
        guard !rom.isEmpty else { return nil }

        switch mapper {
        case .loROM:
            // $00-$7D / $80-$FF : $8000-$FFFF
            guard offset >= 0x8000 else { return nil }
            let b = Int(bank & 0x7F)
            let index = b * 0x8000 + Int(offset - 0x8000)
            return romMask != 0 ? index & romMask : index % rom.count

        case .hiROM:
            let b = Int(bank & 0x7F)
            if b >= 0x40 {
                // $40-$7D / $C0-$FF : banco inteiro
                let index = (b - 0x40) * 0x10000 + Int(offset)
                return romMask != 0 ? index & romMask : index % rom.count
            } else {
                // $00-$3F / $80-$BF : $8000-$FFFF espelha a metade alta do banco
                guard offset >= 0x8000 else { return nil }
                let index = b * 0x10000 + Int(offset)
                return romMask != 0 ? index & romMask : index % rom.count
            }

        case .exHiROM:
            let fullBank = Int(bank)
            let b = fullBank & 0x7F
            // Bancos $00-$3F usam a metade superior da ROM (offset +0x400000)
            let half = (fullBank & 0x80) != 0 ? 0 : 0x400000
            if b >= 0x40 {
                let index = half + (b - 0x40) * 0x10000 + Int(offset)
                return index < rom.count ? index : (romMask != 0 ? index & romMask : index % rom.count)
            } else {
                guard offset >= 0x8000 else { return nil }
                let index = half + b * 0x10000 + Int(offset)
                return index < rom.count ? index : (romMask != 0 ? index & romMask : index % rom.count)
            }
        }
    }

    /// Traduz endereço de CPU em índice de SRAM. Retorna nil se não for área de SRAM.
    @inline(__always)
    func sramIndex(bank: UInt32, offset: UInt32) -> Int? {
        guard !sram.isEmpty else { return nil }

        switch mapper {
        case .loROM:
            // $70-$7D / $F0-$FF : $0000-$7FFF
            let b = bank & 0x7F
            guard b >= 0x70 && b <= 0x7D, offset < 0x8000 else { return nil }
            let index = Int(b - 0x70) * 0x8000 + Int(offset)
            return index % sram.count

        case .hiROM, .exHiROM:
            // $20-$3F / $A0-$BF : $6000-$7FFF
            let b = bank & 0x7F
            guard b >= 0x20 && b <= 0x3F, offset >= 0x6000, offset < 0x8000 else { return nil }
            let index = Int(b - 0x20) * 0x2000 + Int(offset - 0x6000)
            return index % sram.count
        }
    }

    func readROM(_ index: Int) -> UInt8 {
        return rom[index]
    }

    func readSRAM(_ index: Int) -> UInt8 {
        return sram[index]
    }

    func writeSRAM(_ index: Int, _ value: UInt8) {
        if sram[index] != value {
            sram[index] = value
            sramDirty = true
        }
    }

    /// Restaura a SRAM de um .srm. Tamanhos diferentes são copiados até onde couber.
    func setSRAM(_ data: [UInt8]) {
        guard !sram.isEmpty, !data.isEmpty else { return }
        let n = min(data.count, sram.count)
        sram.replaceSubrange(0..<n, with: data[0..<n])
        sramDirty = false
    }

    func markSRAMClean() { sramDirty = false }
    /// Um state carregado pode ter trazido uma SRAM diferente da gravada em disco.
    func markSRAMDirty() { if !sram.isEmpty { sramDirty = true } }
}
