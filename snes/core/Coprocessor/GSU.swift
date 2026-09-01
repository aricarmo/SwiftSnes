//  GSU.swift
//  Super FX (GSU-1/GSU-2): o coprocessador RISC dos cartuchos com gráficos
//  poligonais. Executa código próprio da ROM do cartucho e desenha num
//  framebuffer na RAM do cartucho, que o CPU depois transfere para a VRAM.
//  Port em Swift do core do bsnes (via superfx.cpp).

import Foundation

final class GSUChip {

    // MARK: - Memórias

    /// ROM do cartucho (compartilhada com o Cartridge, nunca mutada aqui).
    private let rom: [UInt8]
    private let romMask: Int
    /// RAM do cartucho (framebuffer + trabalho). O GSU é o dono; o CPU acessa
    /// pelas janelas roteadas no MemoryBus.
    private(set) var ram: [UInt8]
    private let ramMask: Int

    // MARK: - Registradores

    /// R0-R15. R14 = ponteiro do ROM buffer, R15 = program counter.
    private var r = [UInt16](repeating: 0, count: 16)
    /// O core precisa saber se uma instrução escreveu em R14/R15 (dispara o
    /// ROM buffer / suprime o auto-incremento do PC).
    private var rModified = [Bool](repeating: false, count: 16)

    // SFR (status flags)
    private var flagZ = false      // bit 1: zero
    private var flagCY = false     // bit 2: carry
    private var flagS = false      // bit 3: sinal
    private var flagOV = false     // bit 4: overflow
    private var flagG = false      // bit 5: GO (GSU executando)
    private var flagR = false      // bit 6: leitura do ROM buffer pendente
    private var flagAlt1 = false   // bit 8
    private var flagAlt2 = false   // bit 9
    private var flagIL = false     // bit 10
    private var flagIH = false     // bit 11
    private var flagB = false      // bit 12: prefixo WITH ativo
    private var flagIRQ = false    // bit 15

    private var pbr: UInt8 = 0        // banco do programa
    private var rombr: UInt8 = 0      // banco do ROM buffer
    private var rambr = false         // banco da RAM (0/1)
    private var cbr: UInt16 = 0       // base do cache
    private var scbr: UInt8 = 0       // base do screen (RAM << 10)
    private var scmr: UInt8 = 0       // modo do screen (raw)
    private var colr: UInt8 = 0       // cor corrente
    private var por: UInt8 = 0        // opções de plot (raw)
    private var bramr = false
    private var vcr: UInt8 = 0x04     // versão do chip
    private var cfgr: UInt8 = 0       // config (raw)
    private var clsr = false          // clock: false = 10.7MHz, true = 21.4MHz

    private var romcl = 0             // ciclos restantes do ROM buffer
    private var romdr: UInt8 = 0
    private var ramcl = 0             // ciclos restantes do RAM buffer
    private var ramar: UInt16 = 0
    private var ramdr: UInt8 = 0

    private var sreg = 0              // registrador fonte corrente
    private var dreg = 0              // registrador destino corrente

    private var pipeline: UInt8 = 0x01
    private var ramaddr: UInt16 = 0

    // MARK: - Caches

    private var cacheBuffer = [UInt8](repeating: 0, count: 512)
    private var cacheValid = [Bool](repeating: false, count: 32)

    private struct PixelCache {
        var offset: UInt16 = 0xFFFF
        var bitpend: UInt8 = 0
        var data = [UInt8](repeating: 0, count: 8)
    }
    private var pixelcache0 = PixelCache()
    private var pixelcache1 = PixelCache()

    // MARK: - Clock / IRQ

    private var cycleBudget: Int64 = 0
    private(set) var irqActive = false

    // MARK: - Decodificação de registradores raw

    @inline(__always) private var scmrHT: Int {
        (((scmr & 0x20) != 0) ? 2 : 0) | (((scmr & 0x04) != 0) ? 1 : 0)
    }
    @inline(__always) private var scmrRON: Bool { (scmr & 0x10) != 0 }
    @inline(__always) private var scmrRAN: Bool { (scmr & 0x08) != 0 }
    @inline(__always) private var scmrMD: Int { Int(scmr & 0x03) }

    @inline(__always) private var porOBJ: Bool { (por & 0x10) != 0 }
    @inline(__always) private var porFreezeHigh: Bool { (por & 0x08) != 0 }
    @inline(__always) private var porHighNibble: Bool { (por & 0x04) != 0 }
    @inline(__always) private var porDither: Bool { (por & 0x02) != 0 }
    @inline(__always) private var porTransparent: Bool { (por & 0x01) != 0 }

    @inline(__always) private var cfgrIRQMasked: Bool { (cfgr & 0x80) != 0 }
    @inline(__always) private var cfgrMS0: Bool { (cfgr & 0x20) != 0 }

    /// SFR como valor de 16 bits (máscara $9F7E: só os bits que existem).
    private var sfrValue: UInt16 {
        var v: UInt16 = 0
        if flagZ { v |= 1 << 1 }
        if flagCY { v |= 1 << 2 }
        if flagS { v |= 1 << 3 }
        if flagOV { v |= 1 << 4 }
        if flagG { v |= 1 << 5 }
        if flagR { v |= 1 << 6 }
        if flagAlt1 { v |= 1 << 8 }
        if flagAlt2 { v |= 1 << 9 }
        if flagIL { v |= 1 << 10 }
        if flagIH { v |= 1 << 11 }
        if flagB { v |= 1 << 12 }
        if flagIRQ { v |= 1 << 15 }
        return v
    }

    private func setSFRLow(_ data: UInt8) {
        flagZ = (data & 0x02) != 0
        flagCY = (data & 0x04) != 0
        flagS = (data & 0x08) != 0
        flagOV = (data & 0x10) != 0
        flagG = (data & 0x20) != 0
        flagR = (data & 0x40) != 0
    }

    private func setSFRHigh(_ data: UInt8) {
        flagAlt1 = (data & 0x01) != 0
        flagAlt2 = (data & 0x02) != 0
        flagIL = (data & 0x04) != 0
        flagIH = (data & 0x08) != 0
        flagB = (data & 0x10) != 0
        flagIRQ = (data & 0x80) != 0
    }

    // MARK: - Init

    init(rom: [UInt8], ramSize: Int) {
        self.rom = rom
        // ROMs de GSU são potência de 2; se não for, arredonda a máscara para
        // baixo (o acesso além do fim espelha de forma imperfeita, mas nunca sai
        // dos limites).
        self.romMask = rom.count & (rom.count - 1) == 0 ? rom.count - 1 : (1 << (Int.bitWidth - 1 - rom.count.leadingZeroBitCount)) - 1
        let size = max(ramSize, 0x8000)
        self.ram = [UInt8](repeating: 0, count: size)
        self.ramMask = size - 1
        reset()
    }

    func reset() {
        for i in 0..<16 { r[i] = 0; rModified[i] = false }
        flagZ = false; flagCY = false; flagS = false; flagOV = false
        flagG = false; flagR = false; flagAlt1 = false; flagAlt2 = false
        flagIL = false; flagIH = false; flagB = false; flagIRQ = false
        pbr = 0; rombr = 0; rambr = false; cbr = 0
        scbr = 0; scmr = 0; colr = 0; por = 0; bramr = false
        vcr = 0x04; cfgr = 0; clsr = false
        pipeline = 0x01; ramaddr = 0
        sreg = 0; dreg = 0
        romcl = 0; romdr = 0; ramcl = 0; ramar = 0; ramdr = 0
        for i in 0..<512 { cacheBuffer[i] = 0 }
        for i in 0..<32 { cacheValid[i] = false }
        pixelcache0 = PixelCache()
        pixelcache1 = PixelCache()
        for i in 0..<ram.count { ram[i] = 0 }
        cycleBudget = 0
        irqActive = false
    }

    // MARK: - Execução

    /// Avança o GSU pelo equivalente em ciclos master (21.477MHz) do tempo que
    /// o CPU consumiu.
    func run(masterCycles: Int) {
        guard masterCycles > 0 else { return }
        cycleBudget += Int64(masterCycles)
        while cycleBudget > 0 {
            mainStep()
        }
    }

    private func mainStep() {
        if !flagG {
            step(6)
            return
        }

        let opcode = peekpipe()
        execute(opcode)

        if rModified[14] {
            rModified[14] = false
            updateROMBuffer()
        }

        if rModified[15] {
            rModified[15] = false
        } else {
            r[15] &+= 1
        }
    }

    @inline(__always) private func step(_ clocks: Int) {
        if romcl > 0 {
            romcl -= min(clocks, romcl)
            if romcl == 0 {
                flagR = false
                romdr = busRead((UInt32(rombr) << 16) &+ UInt32(r[14]))
            }
        }
        if ramcl > 0 {
            ramcl -= min(clocks, ramcl)
            if ramcl == 0 {
                busWrite(0x700000 &+ (UInt32(rambr ? 1 : 0) << 16) &+ UInt32(ramar), ramdr)
            }
        }
        cycleBudget -= Int64(clocks)
    }

    // MARK: - Registradores auxiliares

    @inline(__always) private func setReg(_ n: Int, _ value: UInt16) {
        r[n] = value
        rModified[n] = true
    }

    @inline(__always) private var sr: UInt16 { r[sreg] }
    @inline(__always) private var dr: UInt16 { r[dreg] }
    @inline(__always) private func setDR(_ value: UInt16) { setReg(dreg, value) }

    /// Fim de instrução: limpa os prefixos WITH/ALT e volta sreg/dreg para R0.
    @inline(__always) private func regReset() {
        flagB = false
        flagAlt1 = false
        flagAlt2 = false
        sreg = 0
        dreg = 0
    }

    // MARK: - Barramento interno do GSU

    @inline(__always) private func romRead(_ addr: UInt32) -> UInt8 {
        rom[Int(addr) & romMask]
    }

    @inline(__always) private func busRead(_ addr: UInt32, _ data: UInt8 = 0) -> UInt8 {
        if (addr & 0xC00000) == 0x000000 {
            // Bancos $00-$3F: metade alta espelha a ROM linearmente
            return romRead(((addr & 0x3F0000) >> 1) | (addr & 0x7FFF))
        }
        if (addr & 0xE00000) == 0x400000 {
            return romRead(addr)
        }
        if (addr & 0xE00000) == 0x600000 {
            return ram[Int(addr) & ramMask]
        }
        return data
    }

    @inline(__always) private func busWrite(_ addr: UInt32, _ data: UInt8) {
        if (addr & 0xE00000) == 0x600000 {
            ram[Int(addr) & ramMask] = data
        }
    }

    // MARK: - Pipeline / cache de instruções

    private func readOpcode(_ addr: UInt16) -> UInt8 {
        let offset = addr &- cbr
        if offset < 512 {
            let block = Int(offset >> 4)
            if !cacheValid[block] {
                var dp = Int(offset & 0xFFF0)
                var sp = (UInt32(pbr) << 16) &+ ((UInt32(cbr) + UInt32(offset & 0xFFF0)) & 0xFFF0)
                for _ in 0..<16 {
                    step(clsr ? 5 : 6)
                    cacheBuffer[dp] = busRead(sp)
                    dp += 1
                    sp &+= 1
                }
                cacheValid[block] = true
            } else {
                step(clsr ? 1 : 2)
            }
            return cacheBuffer[Int(offset)]
        }

        if pbr <= 0x5F {
            syncROMBuffer()
        } else {
            syncRAMBuffer()
        }
        step(clsr ? 5 : 6)
        return busRead((UInt32(pbr) << 16) | UInt32(addr))
    }

    @inline(__always) private func peekpipe() -> UInt8 {
        let result = pipeline
        pipeline = readOpcode(r[15])
        rModified[15] = false
        return result
    }

    @inline(__always) private func pipe() -> UInt8 {
        let result = pipeline
        r[15] &+= 1
        pipeline = readOpcode(r[15])
        rModified[15] = false
        return result
    }

    private func flushCache() {
        for i in 0..<32 { cacheValid[i] = false }
    }

    // MARK: - ROM / RAM buffers

    private func syncROMBuffer() {
        if romcl > 0 { step(romcl) }
    }

    private func readROMBuffer() -> UInt8 {
        syncROMBuffer()
        return romdr
    }

    private func updateROMBuffer() {
        flagR = true
        romcl = clsr ? 5 : 6
    }

    private func syncRAMBuffer() {
        if ramcl > 0 { step(ramcl) }
    }

    private func readRAMBuffer(_ addr: UInt16) -> UInt8 {
        syncRAMBuffer()
        return busRead(0x700000 &+ (UInt32(rambr ? 1 : 0) << 16) &+ UInt32(addr))
    }

    private func writeRAMBuffer(_ addr: UInt16, _ data: UInt8) {
        syncRAMBuffer()
        ramcl = clsr ? 5 : 6
        ramar = addr
        ramdr = data
    }

    // MARK: - Plot

    private func color(_ source: UInt8) -> UInt8 {
        if porHighNibble { return (colr & 0xF0) | (source >> 4) }
        if porFreezeHigh { return (colr & 0xF0) | (source & 0x0F) }
        return source
    }

    /// Número do "character" na organização de tiles do framebuffer.
    @inline(__always) private func charNumber(x: UInt8, y: UInt8) -> Int {
        switch porOBJ ? 3 : scmrHT {
        case 0: return (Int(x & 0xF8) << 1) + (Int(y & 0xF8) >> 3)
        case 1: return (Int(x & 0xF8) << 1) + (Int(x & 0xF8) >> 1) + (Int(y & 0xF8) >> 3)
        case 2: return (Int(x & 0xF8) << 1) + (Int(x & 0xF8) << 0) + (Int(y & 0xF8) >> 3)
        default: return (Int(y & 0x80) << 2) + (Int(x & 0x80) << 1) + (Int(y & 0x78) << 1) + (Int(x & 0x78) >> 3)
        }
    }

    /// Bits por pixel do modo corrente: md 0→2, 1→4, 2→4, 3→8.
    @inline(__always) private var bitsPerPixel: Int {
        let md = scmrMD
        return 2 << (md - (md >> 1))
    }

    private func plot(x: UInt8, y: UInt8) {
        if !porTransparent {
            if scmrMD == 3 {
                if porFreezeHigh {
                    if (colr & 0x0F) == 0 { return }
                } else {
                    if colr == 0 { return }
                }
            } else {
                if (colr & 0x0F) == 0 { return }
            }
        }

        var colorValue = colr
        if porDither && scmrMD != 3 {
            if ((x ^ y) & 1) != 0 { colorValue >>= 4 }
            colorValue &= 0x0F
        }

        let offset = (UInt16(y) << 5) &+ UInt16(x >> 3)
        if offset != pixelcache0.offset {
            flushPixelCache(&pixelcache1)
            pixelcache1 = pixelcache0
            pixelcache0.bitpend = 0
            pixelcache0.offset = offset
        }

        let px = Int((x & 7) ^ 7)
        pixelcache0.data[px] = colorValue
        pixelcache0.bitpend |= UInt8(1 << px)
        if pixelcache0.bitpend == 0xFF {
            flushPixelCache(&pixelcache1)
            pixelcache1 = pixelcache0
            pixelcache0.bitpend = 0
        }
    }

    private func rpix(x: UInt8, y: UInt8) -> UInt8 {
        flushPixelCache(&pixelcache1)
        flushPixelCache(&pixelcache0)

        let cn = charNumber(x: x, y: y)
        let bpp = bitsPerPixel
        let addr = 0x700000 + UInt32(cn * (bpp << 3)) + (UInt32(scbr) << 10) + UInt32(y & 0x07) * 2
        var data: UInt8 = 0
        let px = Int((x & 7) ^ 7)

        for n in 0..<bpp {
            let byte = ((n >> 1) << 4) + (n & 1)
            step(clsr ? 5 : 6)
            data |= UInt8(((Int(busRead(addr + UInt32(byte))) >> px) & 1) << n)
        }

        return data
    }

    private func flushPixelCache(_ entry: inout PixelCache) {
        if entry.bitpend == 0 { return }

        let x = UInt8(truncatingIfNeeded: entry.offset << 3)
        let y = UInt8(truncatingIfNeeded: entry.offset >> 5)

        let cn = charNumber(x: x, y: y)
        let bpp = bitsPerPixel
        let addr = 0x700000 + UInt32(cn * (bpp << 3)) + (UInt32(scbr) << 10) + UInt32(y & 0x07) * 2

        for n in 0..<bpp {
            let byte = UInt32(((n >> 1) << 4) + (n & 1))
            var data: UInt8 = 0
            for px in 0..<8 {
                data |= UInt8(((Int(entry.data[px]) >> n) & 1) << px)
            }
            if entry.bitpend != 0xFF {
                step(clsr ? 5 : 6)
                data &= entry.bitpend
                data |= busRead(addr + byte) & ~entry.bitpend
            }
            step(clsr ? 5 : 6)
            busWrite(addr + byte, data)
        }

        entry.bitpend = 0
    }

    // MARK: - Interface com o CPU (I/O $3000-$34FF)

    func readIO(_ offset: UInt16) -> UInt8 {
        let addr = 0x3000 | (offset & 0x3FF)

        if addr >= 0x3100 && addr <= 0x32FF {
            return cacheBuffer[Int((addr - 0x3100 &+ cbr) & 511)]
        }

        if addr >= 0x3000 && addr <= 0x301F {
            let n = Int((addr >> 1) & 15)
            return (addr & 1) == 0 ? UInt8(r[n] & 0xFF) : UInt8(r[n] >> 8)
        }

        switch addr {
        case 0x3030:
            return UInt8(sfrValue & 0xFF)
        case 0x3031:
            let value = UInt8(sfrValue >> 8)
            flagIRQ = false
            irqActive = false
            return value
        case 0x3034:
            return pbr
        case 0x3036:
            return rombr
        case 0x303B:
            return vcr
        case 0x303C:
            return rambr ? 1 : 0
        case 0x303E:
            return UInt8(cbr & 0xFF)
        case 0x303F:
            return UInt8(cbr >> 8)
        default:
            return 0
        }
    }

    func writeIO(_ offset: UInt16, _ data: UInt8) {
        let addr = 0x3000 | (offset & 0x3FF)

        if addr >= 0x3100 && addr <= 0x32FF {
            let cacheAddr = Int((addr - 0x3100 &+ cbr) & 511)
            cacheBuffer[cacheAddr] = data
            if (cacheAddr & 15) == 15 { cacheValid[cacheAddr >> 4] = true }
            return
        }

        if addr >= 0x3000 && addr <= 0x301F {
            let n = Int((addr >> 1) & 15)
            if (addr & 1) == 0 {
                r[n] = (r[n] & 0xFF00) | UInt16(data)
            } else {
                r[n] = (UInt16(data) << 8) | (r[n] & 0x00FF)
            }
            if n == 14 { updateROMBuffer() }
            // Escrever o byte alto de R15 liga o GO: o GSU começa a executar
            if addr == 0x301F { flagG = true }
            return
        }

        switch addr {
        case 0x3030:
            let wasRunning = flagG
            setSFRLow(data)
            if wasRunning && !flagG {
                cbr = 0
                flushCache()
            }
        case 0x3031:
            setSFRHigh(data)
        case 0x3033:
            bramr = (data & 0x01) != 0
        case 0x3034:
            pbr = data & 0x7F
            flushCache()
        case 0x3037:
            cfgr = data & 0xA0
        case 0x3038:
            scbr = data
        case 0x3039:
            clsr = (data & 0x01) != 0
        case 0x303A:
            scmr = data
        default:
            break
        }
    }

    /// Leitura de ROM pelo CPU. Com o GSU rodando e dono da ROM (RON), o chip
    /// devolve um stub de vetores de interrupção para o CPU não ler lixo.
    func cpuReadROM(index: Int, openBus: UInt8) -> UInt8 {
        if flagG && scmrRON {
            let vector: [UInt8] = [
                0x00, 0x01, 0x00, 0x01, 0x04, 0x01, 0x00, 0x01,
                0x00, 0x01, 0x08, 0x01, 0x00, 0x01, 0x0C, 0x01,
            ]
            return vector[index & 15]
        }
        return rom.isEmpty ? openBus : rom[index & romMask]
    }

    /// Leitura da RAM do cartucho pelo CPU. Com o GSU dono da RAM (RAN), o
    /// barramento devolve open bus.
    func cpuReadRAM(index: Int, openBus: UInt8) -> UInt8 {
        if flagG && scmrRAN { return openBus }
        return ram[index & ramMask]
    }

    func cpuWriteRAM(index: Int, _ value: UInt8) {
        ram[index & ramMask] = value
    }

    // MARK: - Instruções

    private func execute(_ opcode: UInt8) {
        let n = Int(opcode & 0x0F)
        switch opcode {
        case 0x00: opSTOP()
        case 0x01: opNOP()
        case 0x02: opCACHE()
        case 0x03: opLSR()
        case 0x04: opROL()
        case 0x05: opBranch(true)                            // BRA
        case 0x06: opBranch(flagS == flagOV)                 // BGE
        case 0x07: opBranch(flagS != flagOV)                 // BLT
        case 0x08: opBranch(!flagZ)                          // BNE
        case 0x09: opBranch(flagZ)                           // BEQ
        case 0x0A: opBranch(!flagS)                          // BPL
        case 0x0B: opBranch(flagS)                           // BMI
        case 0x0C: opBranch(!flagCY)                         // BCC
        case 0x0D: opBranch(flagCY)                          // BCS
        case 0x0E: opBranch(!flagOV)                         // BVC
        case 0x0F: opBranch(flagOV)                          // BVS
        case 0x10...0x1F: opTO_MOVE(n)
        case 0x20...0x2F: opWITH(n)
        case 0x30...0x3B: opStore(n)
        case 0x3C: opLOOP()
        case 0x3D: opALT1()
        case 0x3E: opALT2()
        case 0x3F: opALT3()
        case 0x40...0x4B: opLoad(n)
        case 0x4C: opPLOT_RPIX()
        case 0x4D: opSWAP()
        case 0x4E: opCOLOR_CMODE()
        case 0x4F: opNOT()
        case 0x50...0x5F: opADD_ADC(n)
        case 0x60...0x6F: opSUB_SBC_CMP(n)
        case 0x70: opMERGE()
        case 0x71...0x7F: opAND_BIC(n)
        case 0x80...0x8F: opMULT_UMULT(n)
        case 0x90: opSBK()
        case 0x91...0x94: opLINK(n)
        case 0x95: opSEX()
        case 0x96: opASR_DIV2()
        case 0x97: opROR()
        case 0x98...0x9D: opJMP_LJMP(n)
        case 0x9E: opLOB()
        case 0x9F: opFMULT_LMULT()
        case 0xA0...0xAF: opIBT_LMS_SMS(n)
        case 0xB0...0xBF: opFROM_MOVES(n)
        case 0xC0: opHIB()
        case 0xC1...0xCF: opOR_XOR(n)
        case 0xD0...0xDE: opINC(n)
        case 0xDF: opGETC_RAMB_ROMB()
        case 0xE0...0xEE: opDEC(n)
        case 0xEF: opGETB()
        default: opIWT_LM_SM(n)   // 0xF0-0xFF
        }
    }

    private func opSTOP() {
        if !cfgrIRQMasked {
            flagIRQ = true
            irqActive = true
        }
        flagG = false
        pipeline = 0x01
        regReset()
    }

    private func opNOP() {
        regReset()
    }

    private func opCACHE() {
        if cbr != (r[15] & 0xFFF0) {
            cbr = r[15] & 0xFFF0
            flushCache()
        }
        regReset()
    }

    private func opLSR() {
        flagCY = (sr & 1) != 0
        setDR(sr >> 1)
        flagS = (dr & 0x8000) != 0
        flagZ = dr == 0
        regReset()
    }

    private func opROL() {
        let carry = (sr & 0x8000) != 0
        setDR((sr << 1) | (flagCY ? 1 : 0))
        flagS = (dr & 0x8000) != 0
        flagCY = carry
        flagZ = dr == 0
        regReset()
    }

    private func opROR() {
        let carry = (sr & 1) != 0
        setDR(((flagCY ? 1 : 0) << 15) | (sr >> 1))
        flagS = (dr & 0x8000) != 0
        flagCY = carry
        flagZ = dr == 0
        regReset()
    }

    private func opBranch(_ take: Bool) {
        let displacement = Int8(bitPattern: pipe())
        if take {
            setReg(15, r[15] &+ UInt16(bitPattern: Int16(displacement)))
        }
    }

    private func opTO_MOVE(_ n: Int) {
        if !flagB {
            dreg = n
        } else {
            setReg(n, sr)
            regReset()
        }
    }

    private func opWITH(_ n: Int) {
        sreg = n
        dreg = n
        flagB = true
    }

    private func opStore(_ n: Int) {
        ramaddr = r[n]
        writeRAMBuffer(ramaddr, UInt8(sr & 0xFF))
        if !flagAlt1 { writeRAMBuffer(ramaddr ^ 1, UInt8(sr >> 8)) }
        regReset()
    }

    private func opLOOP() {
        setReg(12, r[12] &- 1)
        flagS = (r[12] & 0x8000) != 0
        flagZ = r[12] == 0
        if !flagZ { setReg(15, r[13]) }
        regReset()
    }

    private func opALT1() {
        flagB = false
        flagAlt1 = true
    }

    private func opALT2() {
        flagB = false
        flagAlt2 = true
    }

    private func opALT3() {
        flagB = false
        flagAlt1 = true
        flagAlt2 = true
    }

    private func opLoad(_ n: Int) {
        ramaddr = r[n]
        var value = UInt16(readRAMBuffer(ramaddr))
        if !flagAlt1 { value |= UInt16(readRAMBuffer(ramaddr ^ 1)) << 8 }
        setDR(value)
        regReset()
    }

    private func opPLOT_RPIX() {
        if !flagAlt1 {
            plot(x: UInt8(r[1] & 0xFF), y: UInt8(r[2] & 0xFF))
            setReg(1, r[1] &+ 1)
        } else {
            setDR(UInt16(rpix(x: UInt8(r[1] & 0xFF), y: UInt8(r[2] & 0xFF))))
            flagS = (dr & 0x8000) != 0
            flagZ = dr == 0
        }
        regReset()
    }

    private func opSWAP() {
        setDR((sr >> 8) | (sr << 8))
        flagS = (dr & 0x8000) != 0
        flagZ = dr == 0
        regReset()
    }

    private func opCOLOR_CMODE() {
        if !flagAlt1 {
            colr = color(UInt8(sr & 0xFF))
        } else {
            por = UInt8(sr & 0x1F)
        }
        regReset()
    }

    private func opNOT() {
        setDR(~sr)
        flagS = (dr & 0x8000) != 0
        flagZ = dr == 0
        regReset()
    }

    private func opADD_ADC(_ n: Int) {
        let operand = flagAlt2 ? n : Int(r[n])
        let result = Int(sr) + operand + ((flagAlt1 && flagCY) ? 1 : 0)
        flagOV = (~(Int(sr) ^ operand) & (operand ^ result) & 0x8000) != 0
        flagS = (result & 0x8000) != 0
        flagCY = result >= 0x10000
        flagZ = (result & 0xFFFF) == 0
        setDR(UInt16(result & 0xFFFF))
        regReset()
    }

    private func opSUB_SBC_CMP(_ n: Int) {
        let operand = (!flagAlt2 || flagAlt1) ? Int(r[n]) : n
        let borrow = (!flagAlt2 && flagAlt1) ? (flagCY ? 0 : 1) : 0
        let result = Int(sr) - operand - borrow
        flagOV = ((Int(sr) ^ operand) & (Int(sr) ^ result) & 0x8000) != 0
        flagS = (result & 0x8000) != 0
        flagCY = result >= 0
        flagZ = (result & 0xFFFF) == 0
        // CMP (alt1+alt2) só afeta as flags
        if !flagAlt2 || !flagAlt1 { setDR(UInt16(result & 0xFFFF)) }
        regReset()
    }

    private func opMERGE() {
        setDR((r[7] & 0xFF00) | (r[8] >> 8))
        flagOV = (dr & 0xC0C0) != 0
        flagS = (dr & 0x8080) != 0
        flagCY = (dr & 0xE0E0) != 0
        flagZ = (dr & 0xF0F0) != 0
        regReset()
    }

    private func opAND_BIC(_ n: Int) {
        let operand = flagAlt2 ? UInt16(n) : r[n]
        setDR(sr & (flagAlt1 ? ~operand : operand))
        flagS = (dr & 0x8000) != 0
        flagZ = dr == 0
        regReset()
    }

    private func opOR_XOR(_ n: Int) {
        let operand = flagAlt2 ? UInt16(n) : r[n]
        setDR(!flagAlt1 ? (sr | operand) : (sr ^ operand))
        flagS = (dr & 0x8000) != 0
        flagZ = dr == 0
        regReset()
    }

    private func opMULT_UMULT(_ n: Int) {
        let operand = flagAlt2 ? UInt16(n) : r[n]
        if !flagAlt1 {
            let product = Int(Int8(truncatingIfNeeded: sr)) * Int(Int8(truncatingIfNeeded: operand))
            setDR(UInt16(bitPattern: Int16(product)))
        } else {
            let product = Int(UInt8(sr & 0xFF)) * Int(UInt8(operand & 0xFF))
            setDR(UInt16(product))
        }
        flagS = (dr & 0x8000) != 0
        flagZ = dr == 0
        regReset()
        if !cfgrMS0 { step(clsr ? 1 : 2) }
    }

    private func opSBK() {
        writeRAMBuffer(ramaddr ^ 0, UInt8(sr & 0xFF))
        writeRAMBuffer(ramaddr ^ 1, UInt8(sr >> 8))
        regReset()
    }

    private func opLINK(_ n: Int) {
        setReg(11, r[15] &+ UInt16(n))
        regReset()
    }

    private func opSEX() {
        setDR(UInt16(bitPattern: Int16(Int8(truncatingIfNeeded: sr))))
        flagS = (dr & 0x8000) != 0
        flagZ = dr == 0
        regReset()
    }

    private func opASR_DIV2() {
        flagCY = (sr & 1) != 0
        var value = Int(Int16(bitPattern: sr)) >> 1
        // DIV2: corrige -1/2 para 0 (arredonda para o zero)
        if flagAlt1 { value += (Int(sr) + 1) >> 16 }
        setDR(UInt16(bitPattern: Int16(truncatingIfNeeded: value)))
        flagS = (dr & 0x8000) != 0
        flagZ = dr == 0
        regReset()
    }

    private func opJMP_LJMP(_ n: Int) {
        if !flagAlt1 {
            setReg(15, r[n])
        } else {
            pbr = UInt8(r[n] & 0x7F)
            setReg(15, sr)
            cbr = r[15] & 0xFFF0
            flushCache()
        }
        regReset()
    }

    private func opLOB() {
        setDR(sr & 0xFF)
        flagS = (dr & 0x80) != 0
        flagZ = dr == 0
        regReset()
    }

    private func opHIB() {
        setDR(sr >> 8)
        flagS = (dr & 0x80) != 0
        flagZ = dr == 0
        regReset()
    }

    private func opFMULT_LMULT() {
        let product = Int(Int16(bitPattern: sr)) * Int(Int16(bitPattern: r[6]))
        let result = UInt32(bitPattern: Int32(product))
        if flagAlt1 { setReg(4, UInt16(result & 0xFFFF)) }
        setDR(UInt16(result >> 16))
        flagS = (dr & 0x8000) != 0
        flagCY = (result & 0x8000) != 0
        flagZ = dr == 0
        regReset()
        step((cfgrMS0 ? 3 : 7) * (clsr ? 1 : 2))
    }

    private func opIBT_LMS_SMS(_ n: Int) {
        if flagAlt1 {
            // LMS: load de endereço curto (byte << 1)
            ramaddr = UInt16(pipe()) << 1
            let lo = UInt16(readRAMBuffer(ramaddr ^ 0))
            setReg(n, (UInt16(readRAMBuffer(ramaddr ^ 1)) << 8) | lo)
        } else if flagAlt2 {
            // SMS: store de endereço curto
            ramaddr = UInt16(pipe()) << 1
            writeRAMBuffer(ramaddr ^ 0, UInt8(r[n] & 0xFF))
            writeRAMBuffer(ramaddr ^ 1, UInt8(r[n] >> 8))
        } else {
            // IBT: imediato de 8 bits com sinal
            setReg(n, UInt16(bitPattern: Int16(Int8(bitPattern: pipe()))))
        }
        regReset()
    }

    private func opFROM_MOVES(_ n: Int) {
        if !flagB {
            sreg = n
        } else {
            setDR(r[n])
            flagOV = (dr & 0x80) != 0
            flagS = (dr & 0x8000) != 0
            flagZ = dr == 0
            regReset()
        }
    }

    private func opINC(_ n: Int) {
        setReg(n, r[n] &+ 1)
        flagS = (r[n] & 0x8000) != 0
        flagZ = r[n] == 0
        regReset()
    }

    private func opDEC(_ n: Int) {
        setReg(n, r[n] &- 1)
        flagS = (r[n] & 0x8000) != 0
        flagZ = r[n] == 0
        regReset()
    }

    private func opGETC_RAMB_ROMB() {
        if !flagAlt2 {
            colr = color(readROMBuffer())
        } else if !flagAlt1 {
            syncRAMBuffer()
            rambr = (sr & 0x01) != 0
        } else {
            syncROMBuffer()
            rombr = UInt8(sr & 0x7F)
        }
        regReset()
    }

    private func opGETB() {
        switch ((flagAlt2 ? 2 : 0) | (flagAlt1 ? 1 : 0)) {
        case 0: setDR(UInt16(readROMBuffer()))
        case 1: setDR((UInt16(readROMBuffer()) << 8) | (sr & 0xFF))       // GETBH
        case 2: setDR((sr & 0xFF00) | UInt16(readROMBuffer()))            // GETBL
        default: setDR(UInt16(bitPattern: Int16(Int8(bitPattern: readROMBuffer()))))  // GETBS
        }
        regReset()
    }

    private func opIWT_LM_SM(_ n: Int) {
        if flagAlt1 {
            // LM: load de endereço de 16 bits
            ramaddr = UInt16(pipe())
            ramaddr |= UInt16(pipe()) << 8
            let lo = UInt16(readRAMBuffer(ramaddr ^ 0))
            setReg(n, (UInt16(readRAMBuffer(ramaddr ^ 1)) << 8) | lo)
        } else if flagAlt2 {
            // SM: store de endereço de 16 bits
            ramaddr = UInt16(pipe())
            ramaddr |= UInt16(pipe()) << 8
            writeRAMBuffer(ramaddr ^ 0, UInt8(r[n] & 0xFF))
            writeRAMBuffer(ramaddr ^ 1, UInt8(r[n] >> 8))
        } else {
            // IWT: imediato de 16 bits
            let lo = UInt16(pipe())
            setReg(n, (UInt16(pipe()) << 8) | lo)
        }
        regReset()
    }

    /// Estado resumido para diagnóstico (sem efeitos colaterais de leitura).
    var debugSummary: String {
        String(format: "sfr=$%04X pbr=$%02X r15=$%04X r14=$%04X cbr=$%04X scmr=$%02X scbr=$%02X clsr=%d irq=%d",
               sfrValue, pbr, r[15], r[14], cbr, scmr, scbr, clsr ? 1 : 0, irqActive ? 1 : 0)
    }

    // MARK: - Save state

    func serialize(into w: inout StateWriter) {
        w.put(r)
        w.put(rModified)
        w.put(sfrValue)
        w.put(pbr); w.put(rombr); w.put(rambr); w.put(cbr)
        w.put(scbr); w.put(scmr); w.put(colr); w.put(por); w.put(bramr)
        w.put(vcr); w.put(cfgr); w.put(clsr)
        w.put(pipeline); w.put(ramaddr)
        w.put(romcl); w.put(romdr); w.put(ramcl); w.put(ramar); w.put(ramdr)
        w.put(UInt8(sreg)); w.put(UInt8(dreg))
        w.put(cacheBuffer)
        w.put(cacheValid)
        w.put(pixelcache0.offset); w.put(pixelcache0.bitpend); w.put(pixelcache0.data)
        w.put(pixelcache1.offset); w.put(pixelcache1.bitpend); w.put(pixelcache1.data)
        w.put(ram)
        w.put(Int(cycleBudget))
        w.put(irqActive)
    }

    func deserialize(from reader: inout StateReader) throws {
        let regs = try reader.u16s()
        let modified = try reader.bools()
        guard regs.count == 16, modified.count == 16 else { throw StateReader.Error.sizeMismatch }
        r = regs
        rModified = modified
        let sfr = try reader.u16()
        setSFRLow(UInt8(sfr & 0xFF))
        setSFRHigh(UInt8(sfr >> 8))
        pbr = try reader.u8(); rombr = try reader.u8(); rambr = try reader.bool(); cbr = try reader.u16()
        scbr = try reader.u8(); scmr = try reader.u8(); colr = try reader.u8(); por = try reader.u8(); bramr = try reader.bool()
        vcr = try reader.u8(); cfgr = try reader.u8(); clsr = try reader.bool()
        pipeline = try reader.u8(); ramaddr = try reader.u16()
        romcl = try reader.int(); romdr = try reader.u8(); ramcl = try reader.int(); ramar = try reader.u16(); ramdr = try reader.u8()
        sreg = Int(try reader.u8() & 0x0F); dreg = Int(try reader.u8() & 0x0F)
        let cache = try reader.bytes8()
        let valid = try reader.bools()
        guard cache.count == 512, valid.count == 32 else { throw StateReader.Error.sizeMismatch }
        cacheBuffer = cache
        cacheValid = valid
        pixelcache0.offset = try reader.u16(); pixelcache0.bitpend = try reader.u8()
        pixelcache0.data = try reader.bytes8()
        pixelcache1.offset = try reader.u16(); pixelcache1.bitpend = try reader.u8()
        pixelcache1.data = try reader.bytes8()
        guard pixelcache0.data.count == 8, pixelcache1.data.count == 8 else { throw StateReader.Error.sizeMismatch }
        let ramData = try reader.bytes8()
        guard ramData.count == ram.count else { throw StateReader.Error.sizeMismatch }
        ram = ramData
        cycleBudget = Int64(try reader.int())
        irqActive = try reader.bool()
    }
}
