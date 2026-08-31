// MemoryBus.swift
import Foundation

final class MemoryBus {

    // MARK: - Memórias

    private var wram = [UInt8](repeating: 0, count: 0x20000)   // 128KB Work RAM
    let cart = Cartridge()
    private(set) var cartDSP: CartDSPChip?

    // Open bus / MDR: último valor trafegado no barramento
    private var openBus: UInt8 = 0

    // MARK: - Componentes

    // Referências fortes: o barramento é o hub e vive tanto quanto o `SNES`.
    // `SNES.deinit` chama `disconnect()` para quebrar o ciclo com o CPU.
    private var cpu: CPU65816?
    private var ppu: PPU?
    private var apu: APU?

    // MARK: - Registradores de I/O do CPU ($4200-$421F)

    private(set) var nmitimen: UInt8 = 0     // $4200
    private var wrio: UInt8 = 0xFF           // $4201
    private var wrmpya: UInt8 = 0            // $4202
    private var wrdiv: UInt16 = 0            // $4204/$4205
    private var wrdivb: UInt8 = 0            // $4206
    private var htime: UInt16 = 0x1FF        // $4207/$4208
    private var vtime: UInt16 = 0x1FF        // $4209/$420A
    private var memsel: UInt8 = 0            // $420D

    private var rdmpy: UInt16 = 0            // $4216/$4217
    private var rddiv: UInt16 = 0            // $4214/$4215

    private var nmiFlag: Bool = false        // $4210 bit 7
    private var irqFlag: Bool = false        // $4211 bit 7
    private var inVBlank: Bool = false       // $4212 bit 7
    private var inHBlank: Bool = false       // $4212 bit 6
    private var autoJoypadBusy: Bool = false // $4212 bit 0

    // MARK: - WRAM registers ($2180-$2183)

    private var wramAddress: UInt32 = 0

    // MARK: - Controles

    /// Estado dos 4 controles. Formato de $4218: BYsS UDLR AXLR 0000
    var joypadState: [UInt16] = [0, 0, 0, 0]
    private var joypadLatched: [UInt16] = [0, 0, 0, 0]
    private var joypadStrobe: Bool = false
    private var joypadShift: [Int] = [0, 0, 0, 0]

    // MARK: - DMA

    struct DMAChannel {
        var control: UInt8 = 0xFF       // $43x0 DMAPn
        var bAddress: UInt8 = 0xFF      // $43x1 BBADn
        var aAddress: UInt16 = 0xFFFF   // $43x2/3 A1Tn
        var aBank: UInt8 = 0xFF         // $43x4 A1Bn
        var size: UInt16 = 0xFFFF       // $43x5/6 DASn (também endereço indireto HDMA)
        var indirectBank: UInt8 = 0xFF  // $43x7 DASBn
        var tableAddress: UInt16 = 0    // $43x8/9 A2An
        var lineCounter: UInt8 = 0      // $43xA NTRLn
        var unused: UInt8 = 0           // $43xB/F

        // Estado interno HDMA
        var hdmaActive: Bool = false
        var hdmaDoTransfer: Bool = false
        var hdmaTerminated: Bool = false
    }

    private var dma = [DMAChannel](repeating: DMAChannel(), count: 8)
    private var mdmaen: UInt8 = 0
    private var hdmaen: UInt8 = 0

    /// Ciclos consumidos pelas transferências de DMA no frame atual
    private(set) var dmaCycles: Int = 0

    // Quantos bytes cada modo de transferência move por "unidade"
    private static let transferModeSizes = [1, 2, 2, 4, 4, 4, 2, 4]
    // Offsets do endereço B para cada modo
    private static let transferModeOffsets: [[UInt8]] = [
        [0],
        [0, 1],
        [0, 0],
        [0, 0, 1, 1],
        [0, 1, 2, 3],
        [0, 1, 0, 1],
        [0, 0],
        [0, 0, 1, 1]
    ]

    init() {
        reset()
    }

    // MARK: - Conexões

    func connectCPU(_ cpu: CPU65816) { self.cpu = cpu }
    func connectPPU(_ ppu: PPU) { self.ppu = ppu }
    func connectAPU(_ apu: APU) { self.apu = apu }
    func disconnect() { cpu = nil; ppu = nil; apu = nil }

    // MARK: - ROM

    func loadROM(data: Data, firmwareDirectory: URL? = nil) throws {
        try cart.load(data: data)
        attachCartDSP(firmwareDirectory: firmwareDirectory)
    }

    func attachCartDSP(firmwareDirectory: URL? = nil) {
        cartDSP = nil
        guard cart.hasDSP else { return }
        var extra: [URL] = []
        if let firmwareDirectory { extra.append(firmwareDirectory) }
        if let loaded = CartDSPFirmware.load(wanted: cart.dspPart, extraDirectories: extra) {
            cartDSP = CartDSPChip(part: loaded.0.part, image: loaded.1, identity: loaded.0)
            Log.dsp.info("\(loaded.0.part.rawValue, privacy: .public) emulado (µPD77C25)")
        } else {
            let drop = CartDSPFirmware.userFirmwareDirectory()
            try? FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
            Log.dsp.warning("sem firmware para \(self.cart.dspPart.rawValue, privacy: .public); coloque o .rom em \(drop.path, privacy: .public)")
        }
    }

    func advanceCartDSP(cpuCycles: Int) {
        cartDSP?.advance(cpuCycles: cpuCycles)
    }

    // MARK: - Leitura

    func read8(_ address: UInt32) -> UInt8 {
        let bank = (address >> 16) & 0xFF
        let offset = address & 0xFFFF

        switch bank {
        case 0x00...0x3F, 0x80...0xBF:
            switch offset {
            case 0x0000...0x1FFF:
                openBus = wram[Int(offset)]
                return openBus

            case 0x2100...0x213F:
                openBus = ppu?.readRegister(UInt16(offset)) ?? openBus
                return openBus

            case 0x2140...0x217F:
                openBus = apu?.readPort(Int(offset & 0x03)) ?? openBus
                return openBus

            case 0x2180:
                let value = wram[Int(wramAddress & 0x1FFFF)]
                wramAddress = (wramAddress &+ 1) & 0x1FFFF
                openBus = value
                return openBus

            case 0x4016, 0x4017:
                openBus = readJoypadSerial(Int(offset - 0x4016))
                return openBus

            case 0x4200...0x421F:
                return readCPURegister(UInt16(offset))

            case 0x4300...0x437F:
                return readDMARegister(UInt16(offset))

            default:
                if let value = accessCartDSP(bank: bank, offset: offset, write: nil) {
                    openBus = value
                    return openBus
                }
                // Área de ROM nos bancos do sistema
                if offset >= 0x8000, let index = cart.romIndex(bank: bank, offset: offset) {
                    openBus = cart.readROM(index)
                    return openBus
                }
                if let index = cart.sramIndex(bank: bank, offset: offset) {
                    openBus = cart.readSRAM(index)
                    return openBus
                }
                return openBus
            }

        case 0x7E...0x7F:
            let index = Int(bank - 0x7E) * 0x10000 + Int(offset)
            openBus = wram[index]
            return openBus

        default:
            if let value = accessCartDSP(bank: bank, offset: offset, write: nil) {
                openBus = value
                return openBus
            }
            // $40-$7D e $C0-$FF: ROM / SRAM conforme o mapper
            if let index = cart.romIndex(bank: bank, offset: offset) {
                openBus = cart.readROM(index)
                return openBus
            }
            if let index = cart.sramIndex(bank: bank, offset: offset) {
                openBus = cart.readSRAM(index)
                return openBus
            }
            return openBus
        }
    }

    func read16(_ address: UInt32) -> UInt16 {
        let low = UInt16(read8(address))
        let high = UInt16(read8(address &+ 1))
        return (high << 8) | low
    }

    // MARK: - Escrita

    func write8(_ address: UInt32, _ value: UInt8) {
        let bank = (address >> 16) & 0xFF
        let offset = address & 0xFFFF
        openBus = value

        switch bank {
        case 0x00...0x3F, 0x80...0xBF:
            switch offset {
            case 0x0000...0x1FFF:
                wram[Int(offset)] = value

            case 0x2100...0x213F:
                ppu?.writeRegister(UInt16(offset), value)

            case 0x2140...0x217F:
                apu?.writePort(Int(offset & 0x03), value)

            case 0x2180:
                wram[Int(wramAddress & 0x1FFFF)] = value
                wramAddress = (wramAddress &+ 1) & 0x1FFFF

            case 0x2181:
                wramAddress = (wramAddress & 0x1FF00) | UInt32(value)

            case 0x2182:
                wramAddress = (wramAddress & 0x100FF) | (UInt32(value) << 8)

            case 0x2183:
                wramAddress = (wramAddress & 0x0FFFF) | (UInt32(value & 0x01) << 16)

            case 0x4016:
                writeJoypadStrobe(value)

            case 0x4200...0x420D:
                writeCPURegister(UInt16(offset), value)

            case 0x4300...0x437F:
                writeDMARegister(UInt16(offset), value)

            default:
                if accessCartDSP(bank: bank, offset: offset, write: value) != nil {
                    return
                }
                if let index = cart.sramIndex(bank: bank, offset: offset) {
                    cart.writeSRAM(index, value)
                }
            }

        case 0x7E...0x7F:
            let index = Int(bank - 0x7E) * 0x10000 + Int(offset)
            wram[index] = value

        default:
            if accessCartDSP(bank: bank, offset: offset, write: value) != nil {
                return
            }
            if let index = cart.sramIndex(bank: bank, offset: offset) {
                cart.writeSRAM(index, value)
            }
        }
    }

    func write16(_ address: UInt32, _ value: UInt16) {
        write8(address, UInt8(value & 0xFF))
        write8(address &+ 1, UInt8((value >> 8) & 0xFF))
    }

    // MARK: - Cartucho DSP (µPD77C25)

    @discardableResult
    private func accessCartDSP(bank: UInt32, offset: UInt32, write: UInt8?) -> UInt8? {
        guard cart.hasDSP, let isStatus = CartDSPChip.port(bank: bank, offset: offset, mapper: cart.mapper) else {
            return nil
        }
        if let chip = cartDSP {
            if let write {
                chip.write(write, isStatus: isStatus)
                return write
            }
            return chip.read(isStatus: isStatus)
        }
        if write != nil { return write }
        return isStatus ? 0x80 : 0x00
    }

    // MARK: - Registradores do CPU ($4200-$421F)

    private func readCPURegister(_ offset: UInt16) -> UInt8 {
        switch offset {
        case 0x4210:  // RDNMI - NMI ocorrido (limpa na leitura)
            let value: UInt8 = (nmiFlag ? 0x80 : 0x00) | 0x02  // bit 1-3 = versão do CPU
            nmiFlag = false
            openBus = value
            return value

        case 0x4211:  // TIMEUP - IRQ ocorrido (limpa na leitura)
            let value: UInt8 = irqFlag ? 0x80 : 0x00
            irqFlag = false
            openBus = value
            return value

        case 0x4212:  // HVBJOY
            var value: UInt8 = 0
            if inVBlank { value |= 0x80 }
            if inHBlank { value |= 0x40 }
            if autoJoypadBusy { value |= 0x01 }
            openBus = value
            return value

        case 0x4213:  // RDIO
            openBus = wrio
            return wrio

        case 0x4214: openBus = UInt8(rddiv & 0xFF); return openBus
        case 0x4215: openBus = UInt8((rddiv >> 8) & 0xFF); return openBus
        case 0x4216: openBus = UInt8(rdmpy & 0xFF); return openBus
        case 0x4217: openBus = UInt8((rdmpy >> 8) & 0xFF); return openBus

        case 0x4218...0x421F:  // JOY1L..JOY4H (auto-joypad)
            let pad = Int((offset - 0x4218) >> 1)
            let value = joypadLatched[pad]
            openBus = (offset & 1) == 0 ? UInt8(value & 0xFF) : UInt8((value >> 8) & 0xFF)
            return openBus

        default:
            return openBus
        }
    }

    private func writeCPURegister(_ offset: UInt16, _ value: UInt8) {
        switch offset {
        case 0x4200:  // NMITIMEN
            nmitimen = value
            if (value & 0x30) == 0 { irqFlag = false }

        case 0x4201:  // WRIO
            wrio = value

        case 0x4202:  // WRMPYA
            wrmpya = value

        case 0x4203:  // WRMPYB - dispara multiplicação 8x8
            rdmpy = UInt16(wrmpya) * UInt16(value)

        case 0x4204:  // WRDIVL
            wrdiv = (wrdiv & 0xFF00) | UInt16(value)

        case 0x4205:  // WRDIVH
            wrdiv = (wrdiv & 0x00FF) | (UInt16(value) << 8)

        case 0x4206:  // WRDIVB - dispara divisão 16/8
            wrdivb = value
            if value == 0 {
                rddiv = 0xFFFF
                rdmpy = wrdiv
            } else {
                rddiv = wrdiv / UInt16(value)
                rdmpy = wrdiv % UInt16(value)
            }

        case 0x4207: htime = (htime & 0x100) | UInt16(value)
        case 0x4208: htime = (htime & 0x0FF) | (UInt16(value & 0x01) << 8)
        case 0x4209: vtime = (vtime & 0x100) | UInt16(value)
        case 0x420A: vtime = (vtime & 0x0FF) | (UInt16(value & 0x01) << 8)

        case 0x420B:  // MDMAEN - dispara DMA geral
            mdmaen = value
            if value != 0 { runDMA(value) }

        case 0x420C:  // HDMAEN
            hdmaen = value

        case 0x420D:  // MEMSEL - FastROM
            memsel = value

        default:
            break
        }
    }

    // MARK: - Controles

    private func writeJoypadStrobe(_ value: UInt8) {
        let strobe = (value & 0x01) != 0
        if strobe && !joypadStrobe {
            for i in 0..<4 { joypadShift[i] = 0 }
        }
        joypadStrobe = strobe
        if strobe {
            for i in 0..<4 { joypadShift[i] = 0 }
        }
    }

    /// Leitura serial manual em $4016/$4017 (1 bit por leitura, MSB primeiro)
    private func readJoypadSerial(_ port: Int) -> UInt8 {
        let pad = port  // porta 0 -> joypad 1, porta 1 -> joypad 2
        guard pad < 4 else { return 0 }

        let bitIndex = joypadShift[pad]
        var bit: UInt8 = 0
        if bitIndex < 16 {
            bit = UInt8((joypadState[pad] >> (15 - bitIndex)) & 1)
        } else {
            bit = 1  // após 16 bits o controle devolve 1
        }
        if !joypadStrobe {
            joypadShift[pad] = min(bitIndex + 1, 16)
        }
        return bit
    }

    /// Auto-joypad read: executado pelo hardware no início do VBlank
    func performAutoJoypadRead() {
        guard (nmitimen & 0x01) != 0 else { return }
        autoJoypadBusy = true
        for i in 0..<4 {
            joypadLatched[i] = joypadState[i]
            // O auto-read já clockou os 16 bits do controle: leituras seriais em
            // $4016/$4017 depois disso devolvem 1 (controle presente). Alguns
            // jogos usam isso para detectar o controle e zeram o pad se vier 0.
            joypadShift[i] = 16
        }
        autoJoypadBusy = false
    }

    // MARK: - Registradores de DMA ($4300-$437F)

    private func readDMARegister(_ offset: UInt16) -> UInt8 {
        let channel = Int((offset >> 4) & 0x07)
        let reg = offset & 0x0F
        let ch = dma[channel]

        switch reg {
        case 0x0: openBus = ch.control
        case 0x1: openBus = ch.bAddress
        case 0x2: openBus = UInt8(ch.aAddress & 0xFF)
        case 0x3: openBus = UInt8((ch.aAddress >> 8) & 0xFF)
        case 0x4: openBus = ch.aBank
        case 0x5: openBus = UInt8(ch.size & 0xFF)
        case 0x6: openBus = UInt8((ch.size >> 8) & 0xFF)
        case 0x7: openBus = ch.indirectBank
        case 0x8: openBus = UInt8(ch.tableAddress & 0xFF)
        case 0x9: openBus = UInt8((ch.tableAddress >> 8) & 0xFF)
        case 0xA: openBus = ch.lineCounter
        default: openBus = ch.unused
        }
        return openBus
    }

    private func writeDMARegister(_ offset: UInt16, _ value: UInt8) {
        let channel = Int((offset >> 4) & 0x07)
        let reg = offset & 0x0F

        switch reg {
        case 0x0: dma[channel].control = value
        case 0x1: dma[channel].bAddress = value
        case 0x2: dma[channel].aAddress = (dma[channel].aAddress & 0xFF00) | UInt16(value)
        case 0x3: dma[channel].aAddress = (dma[channel].aAddress & 0x00FF) | (UInt16(value) << 8)
        case 0x4: dma[channel].aBank = value
        case 0x5: dma[channel].size = (dma[channel].size & 0xFF00) | UInt16(value)
        case 0x6: dma[channel].size = (dma[channel].size & 0x00FF) | (UInt16(value) << 8)
        case 0x7: dma[channel].indirectBank = value
        case 0x8: dma[channel].tableAddress = (dma[channel].tableAddress & 0xFF00) | UInt16(value)
        case 0x9: dma[channel].tableAddress = (dma[channel].tableAddress & 0x00FF) | (UInt16(value) << 8)
        case 0xA: dma[channel].lineCounter = value
        default: dma[channel].unused = value
        }
    }

    // MARK: - Acesso ao B-bus ($2100-$21FF)

    @inline(__always)
    private func readBBus(_ bAddress: UInt8) -> UInt8 {
        let addr = UInt32(0x2100) | UInt32(bAddress)
        return read8(addr)
    }

    @inline(__always)
    private func writeBBus(_ bAddress: UInt8, _ value: UInt8) {
        let addr = UInt32(0x2100) | UInt32(bAddress)
        write8(addr, value)
    }

    // MARK: - DMA geral

    private func runDMA(_ mask: UInt8) {
        for channel in 0..<8 where (mask & (1 << UInt8(channel))) != 0 {
            runDMAChannel(channel)
        }
        mdmaen = 0
    }

    private func runDMAChannel(_ channel: Int) {
        var ch = dma[channel]

        let mode = Int(ch.control & 0x07)
        let direction = (ch.control & 0x80) != 0   // true = B -> A
        let fixed = (ch.control & 0x08) != 0
        let decrement = (ch.control & 0x10) != 0

        let offsets = MemoryBus.transferModeOffsets[mode]
        var step = 0

        // size == 0 significa 65536 bytes
        var remaining = Int(ch.size) == 0 ? 0x10000 : Int(ch.size)
        // O DMA move 1 byte a cada 8 ciclos master, e um ciclo de CPU equivale a
        // 8 ciclos master: portanto 1 byte por ciclo de CPU, mais a sobrecarga
        // de inicialização do canal.
        dmaCycles += 8 + remaining

        var aAddr = ch.aAddress

        while remaining > 0 {
            let bAddr = ch.bAddress &+ offsets[step % offsets.count]
            let fullA = (UInt32(ch.aBank) << 16) | UInt32(aAddr)

            if direction {
                // B -> A (ex.: leitura de VRAM para WRAM)
                let value = readBBus(bAddr)
                write8(fullA, value)
            } else {
                // A -> B (caso comum: WRAM/ROM -> VRAM/CGRAM/OAM)
                let value = read8(fullA)
                writeBBus(bAddr, value)
            }

            if !fixed {
                aAddr = decrement ? (aAddr &- 1) : (aAddr &+ 1)
            }

            step += 1
            remaining -= 1
        }

        // Hardware zera DAS e atualiza A1T ao terminar
        ch.aAddress = aAddr
        ch.size = 0
        dma[channel] = ch
    }

    // MARK: - HDMA

    /// Inicializa as tabelas HDMA no começo do frame (scanline 0)
    func hdmaInit() {
        for channel in 0..<8 {
            dma[channel].hdmaActive = false
            dma[channel].hdmaDoTransfer = false
            dma[channel].hdmaTerminated = false

            guard (hdmaen & (1 << UInt8(channel))) != 0 else { continue }

            dma[channel].tableAddress = dma[channel].aAddress
            dma[channel].hdmaActive = true
            loadHDMALineCount(channel)
        }
    }

    private func loadHDMALineCount(_ channel: Int) {
        var ch = dma[channel]
        let base = (UInt32(ch.aBank) << 16)

        let count = read8(base | UInt32(ch.tableAddress))
        ch.tableAddress = ch.tableAddress &+ 1

        if count == 0 {
            ch.hdmaActive = false
            ch.hdmaTerminated = true
            dma[channel] = ch
            return
        }

        ch.lineCounter = count
        ch.hdmaDoTransfer = true

        // Modo indireto: lê o ponteiro de 16 bits que segue o contador
        if (ch.control & 0x40) != 0 {
            let low = read8(base | UInt32(ch.tableAddress))
            ch.tableAddress = ch.tableAddress &+ 1
            let high = read8(base | UInt32(ch.tableAddress))
            ch.tableAddress = ch.tableAddress &+ 1
            ch.size = UInt16(low) | (UInt16(high) << 8)
        }

        dma[channel] = ch
    }

    /// Executa uma linha de HDMA. Chamado a cada scanline visível.
    func hdmaRun() {
        for channel in 0..<8 {
            guard dma[channel].hdmaActive else { continue }

            var ch = dma[channel]
            let mode = Int(ch.control & 0x07)
            let indirect = (ch.control & 0x40) != 0
            let unitSize = MemoryBus.transferModeSizes[mode]
            let offsets = MemoryBus.transferModeOffsets[mode]

            if ch.hdmaDoTransfer {
                for i in 0..<unitSize {
                    let bAddr = ch.bAddress &+ offsets[i % offsets.count]
                    let sourceAddr: UInt32
                    if indirect {
                        sourceAddr = (UInt32(ch.indirectBank) << 16) | UInt32(ch.size &+ UInt16(i))
                    } else {
                        sourceAddr = (UInt32(ch.aBank) << 16) | UInt32(ch.tableAddress &+ UInt16(i))
                    }
                    writeBBus(bAddr, read8(sourceAddr))
                }
                dmaCycles += unitSize

                if indirect {
                    ch.size = ch.size &+ UInt16(unitSize)
                } else {
                    ch.tableAddress = ch.tableAddress &+ UInt16(unitSize)
                }
            }

            // Decrementa o contador de linhas
            ch.lineCounter = ch.lineCounter &- 1
            // Bit 7 do contador = "repetir a cada linha"
            ch.hdmaDoTransfer = (ch.lineCounter & 0x80) != 0

            if (ch.lineCounter & 0x7F) == 0 {
                dma[channel] = ch
                loadHDMALineCount(channel)
            } else {
                dma[channel] = ch
            }
        }
    }

    // MARK: - Sinais do PPU

    func setVBlank(_ value: Bool) {
        if value && !inVBlank {
            nmiFlag = true
            performAutoJoypadRead()
            if (nmitimen & 0x80) != 0 {
                cpu?.triggerNMI()
            }
        }
        inVBlank = value
        if !value { nmiFlag = false }
    }

    func setHBlank(_ value: Bool) {
        inHBlank = value
    }

    /// Verifica IRQ por H/V counter e dispara se configurado
    func checkTimerIRQ(scanline: Int, dot: Int) {
        let mode = (nmitimen >> 4) & 0x03
        guard mode != 0 else { return }

        var trigger = false
        switch mode {
        case 1: trigger = dot == Int(htime)                               // H-IRQ
        case 2: trigger = scanline == Int(vtime) && dot == 0              // V-IRQ
        case 3: trigger = scanline == Int(vtime) && dot == Int(htime)     // H+V IRQ
        default: break
        }

        if trigger {
            irqFlag = true
            cpu?.triggerIRQ()
        }
    }

    var isFastROMEnabled: Bool { (memsel & 0x01) != 0 }

    // MARK: - Reset

    func reset() {
        for i in 0..<wram.count { wram[i] = 0 }

        nmitimen = 0
        wrio = 0xFF
        wrmpya = 0
        wrdiv = 0
        wrdivb = 0
        htime = 0x1FF
        vtime = 0x1FF
        memsel = 0
        rdmpy = 0
        rddiv = 0

        nmiFlag = false
        irqFlag = false
        inVBlank = false
        inHBlank = false
        autoJoypadBusy = false

        wramAddress = 0
        openBus = 0

        mdmaen = 0
        hdmaen = 0
        dmaCycles = 0
        for i in 0..<8 { dma[i] = DMAChannel() }

        joypadLatched = [0, 0, 0, 0]
        joypadShift = [0, 0, 0, 0]
        joypadStrobe = false

        cartDSP?.boot()
    }

    func resetDMACycles() { dmaCycles = 0 }

    // MARK: - Save state

    func serialize(into w: inout StateWriter) {
        w.put(wram); w.put(cart.sram); w.put(openBus)
        w.put(nmitimen); w.put(wrio); w.put(wrmpya); w.put(wrdiv); w.put(wrdivb)
        w.put(htime); w.put(vtime); w.put(memsel); w.put(rdmpy); w.put(rddiv)
        w.put(nmiFlag); w.put(irqFlag); w.put(inVBlank); w.put(inHBlank); w.put(autoJoypadBusy)
        w.put(wramAddress)
        w.put(joypadLatched); w.put(joypadStrobe); w.put(joypadShift)
        for ch in dma {
            w.put(ch.control); w.put(ch.bAddress); w.put(ch.aAddress); w.put(ch.aBank)
            w.put(ch.size); w.put(ch.indirectBank); w.put(ch.tableAddress); w.put(ch.lineCounter); w.put(ch.unused)
            w.put(ch.hdmaActive); w.put(ch.hdmaDoTransfer); w.put(ch.hdmaTerminated)
        }
        w.put(mdmaen); w.put(hdmaen); w.put(dmaCycles)
        w.put(cartDSP != nil)
        cartDSP?.serialize(into: &w)
    }

    func deserialize(from r: inout StateReader) throws {
        wram = try r.bytes8(count: wram.count)
        let sram = try r.bytes8()
        guard sram.count == cart.sram.count else { throw StateReader.Error.sizeMismatch }
        cart.setSRAM(sram)
        cart.markSRAMDirty()
        openBus = try r.u8()
        nmitimen = try r.u8(); wrio = try r.u8(); wrmpya = try r.u8(); wrdiv = try r.u16(); wrdivb = try r.u8()
        htime = try r.u16(); vtime = try r.u16(); memsel = try r.u8(); rdmpy = try r.u16(); rddiv = try r.u16()
        nmiFlag = try r.bool(); irqFlag = try r.bool(); inVBlank = try r.bool(); inHBlank = try r.bool(); autoJoypadBusy = try r.bool()
        wramAddress = try r.u32()
        joypadLatched = try r.u16s(); joypadStrobe = try r.bool(); joypadShift = try r.ints()
        guard joypadLatched.count == 4, joypadShift.count == 4 else { throw StateReader.Error.sizeMismatch }
        for i in 0..<8 {
            var ch = DMAChannel()
            ch.control = try r.u8(); ch.bAddress = try r.u8(); ch.aAddress = try r.u16(); ch.aBank = try r.u8()
            ch.size = try r.u16(); ch.indirectBank = try r.u8(); ch.tableAddress = try r.u16(); ch.lineCounter = try r.u8(); ch.unused = try r.u8()
            ch.hdmaActive = try r.bool(); ch.hdmaDoTransfer = try r.bool(); ch.hdmaTerminated = try r.bool()
            dma[i] = ch
        }
        mdmaen = try r.u8(); hdmaen = try r.u8(); dmaCycles = try r.int()
        let hasDSP = try r.bool()
        guard hasDSP == (cartDSP != nil) else { throw StateReader.Error.sizeMismatch }
        try cartDSP?.deserialize(from: &r)
    }
}
