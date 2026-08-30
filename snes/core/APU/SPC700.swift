import Foundation

// MARK: - SPC700

final class SPC700 {
    // Registers
    var a: UInt8 = 0
    var x: UInt8 = 0
    var y: UInt8 = 0
    var sp: UInt8 = 0xEF
    var pc: UInt16 = 0xFFC0  // boot ROM entry

    // PSW flags
    var flagN = false  // negative
    var flagV = false  // overflow
    var flagP = false  // direct page (0=$0000, 1=$0100)
    var flagH = false  // half-carry
    var flagZ = false  // zero
    var flagC = false  // carry
    var flagB = false  // break (bit 4)
    var flagI = false  // interrupt enable (bit 2, unused on SNES)

    // Memory
    var ram = [UInt8](repeating: 0, count: 65536)

    // I/O ports (shared with main CPU)
    var portsFromCPU = [UInt8](repeating: 0, count: 4)  // CPU writes, SPC reads ($F4-$F7)
    var portsToCPU = [UInt8](repeating: 0, count: 4)     // SPC writes, CPU reads ($F4-$F7)

    // DSP interface
    var dspAddr: UInt8 = 0  // $F2
    var dsp: DSPInterface?

    // Timer state
    var timerEnabled = [false, false, false]
    var timerDivisor: [UInt8] = [0, 0, 0]
    var timerCounter: [UInt8] = [0, 0, 0]  // 4-bit, read-only, clear on read
    var timerInternal: [UInt16] = [0, 0, 0]
    var timerStage1 = [false, false, false]
    var timerLine = [false, false, false]
    var timerStage2 = [0, 0, 0]
    var timersDisable = false
    var timersEnable = true

    // Boot ROM
    var bootRomEnabled = true
    static let bootROM: [UInt8] = [
        0xCD, 0xEF, 0xBD, 0xE8, 0x00, 0xC6, 0x1D, 0xD0,
        0xFC, 0x8F, 0xAA, 0xF4, 0x8F, 0xBB, 0xF5, 0x78,
        0xCC, 0xF4, 0xD0, 0xFB, 0x2F, 0x19, 0xEB, 0xF4,
        0xD0, 0xFC, 0x7E, 0xF4, 0xD0, 0x0B, 0xE4, 0xF5,
        0xCB, 0xF4, 0xD7, 0x00, 0xFC, 0xD0, 0xF3, 0xAB,
        0x01, 0x10, 0xEF, 0x7E, 0xF4, 0x10, 0xEB, 0xBA,
        0xF6, 0xDA, 0x00, 0xBA, 0xF4, 0xC4, 0xF4, 0xDD,
        0x5D, 0xD0, 0xDB, 0x1F, 0x00, 0x00, 0xC0, 0xFF
    ]

    // Cycle tracking
    var cycles = 0

    // Stopped/sleeping
    var stopped = false
    var sleeping = false

    func reset() {
        a = 0; x = 0; y = 0
        sp = 0xEF
        pc = 0xFFC0
        bootRomEnabled = true
        flagN = false; flagV = false; flagP = false
        flagH = false; flagZ = false; flagC = false
        flagB = false; flagI = false
        stopped = false; sleeping = false
        for i in 0..<4 { portsFromCPU[i] = 0; portsToCPU[i] = 0 }
        for i in 0..<3 {
            timerEnabled[i] = false; timerDivisor[i] = 0
            timerCounter[i] = 0; timerInternal[i] = 0
            timerStage1[i] = false; timerLine[i] = false; timerStage2[i] = 0
        }
        timersDisable = false
        timersEnable = true
    }

    // MARK: - PSW

    var psw: UInt8 {
        get {
            var v: UInt8 = 0
            if flagC { v |= 0x01 }
            if flagZ { v |= 0x02 }
            if flagI { v |= 0x04 }
            if flagH { v |= 0x08 }
            if flagB { v |= 0x10 }
            if flagP { v |= 0x20 }
            if flagV { v |= 0x40 }
            if flagN { v |= 0x80 }
            return v
        }
        set {
            flagC = (newValue & 0x01) != 0
            flagZ = (newValue & 0x02) != 0
            flagI = (newValue & 0x04) != 0
            flagH = (newValue & 0x08) != 0
            flagB = (newValue & 0x10) != 0
            flagP = (newValue & 0x20) != 0
            flagV = (newValue & 0x40) != 0
            flagN = (newValue & 0x80) != 0
        }
    }

    // MARK: - Helpers

    private var dpBase: UInt16 { flagP ? 0x0100 : 0x0000 }

    private func dpAddr(_ offset: UInt8) -> UInt16 { dpBase | UInt16(offset) }

    private func setNZ(_ val: UInt8) {
        flagN = (val & 0x80) != 0
        flagZ = val == 0
    }

    private func push8(_ val: UInt8) {
        ram[0x0100 | Int(sp)] = val
        sp &-= 1
    }

    private func pull8() -> UInt8 {
        sp &+= 1
        return ram[0x0100 | Int(sp)]
    }

    private func push16(_ val: UInt16) {
        push8(UInt8(val >> 8))
        push8(UInt8(val & 0xFF))
    }

    private func pull16() -> UInt16 {
        let lo = UInt16(pull8())
        let hi = UInt16(pull8())
        return (hi << 8) | lo
    }

    // MARK: - Memory Access

    @inline(__always)
    func read(_ addr: UInt16) -> UInt8 {
        // Fast path: most reads are plain RAM (not I/O range $F0-$FF or boot ROM)
        if addr < 0xF0 || (addr >= 0x100 && addr < 0xFFC0) {
            return ram[Int(addr)]
        }
        return readIO(addr)
    }

    private func readIO(_ addr: UInt16) -> UInt8 {
        switch addr {
        case 0xF0: return 0  // TEST register
        case 0xF1: return 0  // CONTROL (write-only)
        case 0xF2: return dspAddr
        case 0xF3: return dsp?.read(register: dspAddr) ?? 0
        case 0xF4...0xF7: return portsFromCPU[Int(addr - 0xF4)]
        case 0xF8...0xF9: return ram[Int(addr)]
        case 0xFA...0xFC: return 0  // timer divisors (write-only)
        case 0xFD:
            let v = timerCounter[0]; timerCounter[0] = 0; return v
        case 0xFE:
            let v = timerCounter[1]; timerCounter[1] = 0; return v
        case 0xFF:
            let v = timerCounter[2]; timerCounter[2] = 0; return v
        case 0xFFC0...0xFFFF:
            if bootRomEnabled { return SPC700.bootROM[Int(addr - 0xFFC0)] }
            return ram[Int(addr)]
        default:
            return ram[Int(addr)]
        }
    }

    func write(_ addr: UInt16, value: UInt8) {
        ram[Int(addr)] = value  // always write to RAM (even I/O range)
        switch addr {
        case 0xF0:  // TEST
            guard !flagP else { break }
            timersDisable = (value & 0x01) != 0
            timersEnable = (value & 0x08) != 0
            for i in 0..<3 { synchronizeTimerStage1(i) }
        case 0xF1:  // CONTROL
            if (value & 0x10) != 0 { portsFromCPU[0] = 0; portsFromCPU[1] = 0 }
            if (value & 0x20) != 0 { portsFromCPU[2] = 0; portsFromCPU[3] = 0 }
            // Reset internal state when a timer transitions from disabled to enabled
            for i in 0..<3 {
                let newEnabled = (value & UInt8(1 << i)) != 0
                if newEnabled && !timerEnabled[i] {
                    timerStage2[i] = 0
                    timerCounter[i] = 0
                }
                timerEnabled[i] = newEnabled
            }
            bootRomEnabled = (value & 0x80) != 0
        case 0xF2: dspAddr = value
        case 0xF3: dsp?.write(register: dspAddr, value: value)
        case 0xF4...0xF7: portsToCPU[Int(addr - 0xF4)] = value
        case 0xFA: timerDivisor[0] = value
        case 0xFB: timerDivisor[1] = value
        case 0xFC: timerDivisor[2] = value
        default: break
        }
    }

    // Read 16-bit value (little-endian)
    private func read16(_ addr: UInt16) -> UInt16 {
        let lo = UInt16(read(addr))
        let hi = UInt16(read(addr &+ 1))
        return (hi << 8) | lo
    }

    private func write16(_ addr: UInt16, value: UInt16) {
        write(addr, value: UInt8(value & 0xFF))
        write(addr &+ 1, value: UInt8(value >> 8))
    }

    // MARK: - Fetch

    @inline(__always)
    private func fetchByte() -> UInt8 {
        let v = read(pc)
        pc &+= 1
        return v
    }

    private func fetchWord() -> UInt16 {
        let lo = UInt16(fetchByte())
        let hi = UInt16(fetchByte())
        return (hi << 8) | lo
    }

    // MARK: - Addressing mode helpers

    /// Direct page byte
    private func readDP(_ offset: UInt8) -> UInt8 {
        read(dpAddr(offset))
    }

    private func writeDP(_ offset: UInt8, value: UInt8) {
        write(dpAddr(offset), value: value)
    }

    /// Direct page 16-bit (wraps within page: offset $FF wraps to $00)
    private func readDP16(_ offset: UInt8) -> UInt16 {
        let lo = UInt16(read(dpAddr(offset)))
        let hi = UInt16(read(dpAddr(offset &+ 1)))
        return (hi << 8) | lo
    }

    private func writeDP16(_ offset: UInt8, value: UInt16) {
        write(dpAddr(offset), value: UInt8(value & 0xFF))
        write(dpAddr(offset &+ 1), value: UInt8(value >> 8))
    }

    /// Indirect indexed: [dp+X] — pointer wraps within direct page
    private func addrIndirectX(_ dp: UInt8) -> UInt16 {
        return readDP16(dp &+ x)
    }

    /// Indexed indirect: [dp]+Y — pointer wraps within direct page
    private func addrIndirectY(_ dp: UInt8) -> UInt16 {
        return readDP16(dp) &+ UInt16(y)
    }

    // MARK: - ALU Operations

    private func doADC(_ a: UInt8, _ b: UInt8) -> UInt8 {
        let c: UInt16 = flagC ? 1 : 0
        let sum = UInt16(a) + UInt16(b) + c
        let result = UInt8(sum & 0xFF)
        flagC = sum > 0xFF
        flagV = (~(UInt16(a) ^ UInt16(b)) & (UInt16(a) ^ sum) & 0x80) != 0
        flagH = ((a & 0x0F) + (b & 0x0F) + UInt8(c)) > 0x0F
        setNZ(result)
        return result
    }

    private func doSBC(_ a: UInt8, _ b: UInt8) -> UInt8 {
        let c: UInt16 = flagC ? 0 : 1
        let diff = UInt16(a) &- UInt16(b) &- c
        let result = UInt8(diff & 0xFF)
        flagC = diff < 0x100  // no borrow
        flagV = ((UInt16(a) ^ UInt16(b)) & (UInt16(a) ^ diff) & 0x80) != 0
        flagH = (Int(a & 0x0F) - Int(b & 0x0F) - Int(c)) >= 0
        setNZ(result)
        return result
    }

    private func doCMP(_ a: UInt8, _ b: UInt8) {
        let diff = Int(a) - Int(b)
        flagC = diff >= 0
        setNZ(UInt8(diff & 0xFF))
    }

    private func doADW(_ lhs: UInt16, _ rhs: UInt16) -> UInt16 {
        flagC = false
        let lo = doADC(UInt8(lhs & 0x00FF), UInt8(rhs & 0x00FF))
        let hi = doADC(UInt8(lhs >> 8), UInt8(rhs >> 8))
        let result = UInt16(hi) << 8 | UInt16(lo)
        flagZ = result == 0
        return result
    }

    private func doSBW(_ lhs: UInt16, _ rhs: UInt16) -> UInt16 {
        flagC = true
        let lo = doSBC(UInt8(lhs & 0x00FF), UInt8(rhs & 0x00FF))
        let hi = doSBC(UInt8(lhs >> 8), UInt8(rhs >> 8))
        let result = UInt16(hi) << 8 | UInt16(lo)
        flagZ = result == 0
        return result
    }

    private func doCPW(_ lhs: UInt16, _ rhs: UInt16) {
        let diff = Int(lhs) - Int(rhs)
        flagC = diff >= 0
        let result = UInt16(truncatingIfNeeded: diff)
        flagN = (result & 0x8000) != 0
        flagZ = result == 0
    }

    private func doAND(_ a: UInt8, _ b: UInt8) -> UInt8 {
        let r = a & b; setNZ(r); return r
    }

    private func doOR(_ a: UInt8, _ b: UInt8) -> UInt8 {
        let r = a | b; setNZ(r); return r
    }

    private func doEOR(_ a: UInt8, _ b: UInt8) -> UInt8 {
        let r = a ^ b; setNZ(r); return r
    }

    private func doASL(_ v: UInt8) -> UInt8 {
        flagC = (v & 0x80) != 0
        let r = v << 1
        setNZ(r)
        return r
    }

    private func doLSR(_ v: UInt8) -> UInt8 {
        flagC = (v & 0x01) != 0
        let r = v >> 1
        setNZ(r)
        return r
    }

    private func doROL(_ v: UInt8) -> UInt8 {
        let c: UInt8 = flagC ? 1 : 0
        flagC = (v & 0x80) != 0
        let r = (v << 1) | c
        setNZ(r)
        return r
    }

    private func doROR(_ v: UInt8) -> UInt8 {
        let c: UInt8 = flagC ? 0x80 : 0
        flagC = (v & 0x01) != 0
        let r = (v >> 1) | c
        setNZ(r)
        return r
    }

    // MARK: - Branch helper

    private func branch(_ cond: Bool) -> Int {
        let rel = fetchByte()
        if cond {
            let offset = Int8(bitPattern: rel)
            pc = UInt16(Int(pc) + Int(offset))
            return 4
        }
        return 2
    }

    // MARK: - Bit address helpers (for OR1/AND1/EOR1/MOV1/NOT1)

    /// Parse a 16-bit operand as addr:bit — returns (absolute address, bit number 0-7)
    private func parseBitAddr(_ operand: UInt16) -> (UInt16, UInt8) {
        let addr = operand & 0x1FFF
        let bit = UInt8((operand >> 13) & 0x07)
        return (addr, bit)
    }

    // MARK: - Timer tick

    private func synchronizeTimerStage1(_ index: Int) {
        var level = timerStage1[index]
        if !timersEnable { level = false }
        if timersDisable { level = false }

        let fallingEdge = timerLine[index] && !level
        timerLine[index] = level
        guard fallingEdge, timerEnabled[index] else { return }

        timerStage2[index] = (timerStage2[index] + 1) & 0xFF
        if timerStage2[index] != Int(timerDivisor[index]) { return }

        timerStage2[index] = 0
        timerCounter[index] = (timerCounter[index] &+ 1) & 0x0F
    }

    func tickTimers(cpuCycles: Int) {
        // Timers keep their stage-0/stage-1 clocks even while disabled.
        // The enable bit only gates the stage-2 pulse that increments T0OUT/T1OUT/T2OUT.
        for i in 0..<3 {
            timerInternal[i] &+= UInt16(cpuCycles)
            let threshold: UInt16 = (i < 2) ? 128 : 16
            while timerInternal[i] >= threshold {
                timerInternal[i] &-= threshold
                timerStage1[i].toggle()
                synchronizeTimerStage1(i)
            }
        }
    }

    // MARK: - Step (execute one instruction)

    func step() -> Int {
        if stopped || sleeping {
            // WAIT/STOP keep the already-advanced PC and repeatedly idle on it.
            _ = read(pc)
            return 2
        }

        let opcode = fetchByte()

        let cycles: Int = {
            switch opcode {

        // ============================================================
        // NOP
        // ============================================================
        case 0x00: // NOP
            return 2

        // ============================================================
        // TCALL 0-15
        // ============================================================
        case 0x01, 0x11, 0x21, 0x31, 0x41, 0x51, 0x61, 0x71,
             0x81, 0x91, 0xA1, 0xB1, 0xC1, 0xD1, 0xE1, 0xF1:
            let n = Int(opcode >> 4)
            push16(pc)
            let vectorAddr = UInt16(0xFFDE - (n * 2))
            pc = read16(vectorAddr)
            return 8

        // ============================================================
        // SET1 / CLR1
        // ============================================================
        case 0x02, 0x22, 0x42, 0x62, 0x82, 0xA2, 0xC2, 0xE2: // SET1 dp.bit
            let bit = (opcode >> 5)
            let dp = fetchByte()
            let addr = dpAddr(dp)
            let v = read(addr) | (1 << bit)
            write(addr, value: v)
            return 4

        case 0x12, 0x32, 0x52, 0x72, 0x92, 0xB2, 0xD2, 0xF2: // CLR1 dp.bit
            let bit = (opcode >> 5)
            let dp = fetchByte()
            let addr = dpAddr(dp)
            let v = read(addr) & ~(1 << bit)
            write(addr, value: v)
            return 4

        // ============================================================
        // BBS / BBC (branch on bit set/clear)
        // ============================================================
        case 0x03, 0x23, 0x43, 0x63, 0x83, 0xA3, 0xC3, 0xE3: // BBS bit,dp,rel
            let bit = (opcode >> 5)
            let dp = fetchByte()
            let rel = fetchByte()
            let v = readDP(dp)
            if (v & (1 << bit)) != 0 {
                pc = UInt16(Int(pc) + Int(Int8(bitPattern: rel)))
                return 7
            }
            return 5

        case 0x13, 0x33, 0x53, 0x73, 0x93, 0xB3, 0xD3, 0xF3: // BBC bit,dp,rel
            let bit = (opcode >> 5)
            let dp = fetchByte()
            let rel = fetchByte()
            let v = readDP(dp)
            if (v & (1 << bit)) == 0 {
                pc = UInt16(Int(pc) + Int(Int8(bitPattern: rel)))
                return 7
            }
            return 5

        // ============================================================
        // OR A, ...
        // ============================================================
        case 0x08: // OR A, #imm
            a = doOR(a, fetchByte()); return 2
        case 0x06: // OR A, (X)
            a = doOR(a, read(dpAddr(x))); return 3
        case 0x04: // OR A, dp
            a = doOR(a, readDP(fetchByte())); return 3
        case 0x14: // OR A, dp+X
            a = doOR(a, readDP(fetchByte() &+ x)); return 4
        case 0x05: // OR A, !abs
            a = doOR(a, read(fetchWord())); return 4
        case 0x15: // OR A, !abs+X
            a = doOR(a, read(fetchWord() &+ UInt16(x))); return 5
        case 0x16: // OR A, !abs+Y
            a = doOR(a, read(fetchWord() &+ UInt16(y))); return 5
        case 0x07: // OR A, [dp+X]
            a = doOR(a, read(addrIndirectX(fetchByte()))); return 6
        case 0x17: // OR A, [dp]+Y
            a = doOR(a, read(addrIndirectY(fetchByte()))); return 6
        case 0x09: // OR dp, dp
            let src = fetchByte(); let dst = fetchByte()
            let v = doOR(readDP(dst), readDP(src))
            writeDP(dst, value: v); return 6
        case 0x18: // OR dp, #imm
            let imm = fetchByte(); let dp = fetchByte()
            let v = doOR(readDP(dp), imm)
            writeDP(dp, value: v); return 5

        // ============================================================
        // AND A, ...
        // ============================================================
        case 0x28: // AND A, #imm
            a = doAND(a, fetchByte()); return 2
        case 0x26: // AND A, (X)
            a = doAND(a, read(dpAddr(x))); return 3
        case 0x24: // AND A, dp
            a = doAND(a, readDP(fetchByte())); return 3
        case 0x34: // AND A, dp+X
            a = doAND(a, readDP(fetchByte() &+ x)); return 4
        case 0x25: // AND A, !abs
            a = doAND(a, read(fetchWord())); return 4
        case 0x35: // AND A, !abs+X
            a = doAND(a, read(fetchWord() &+ UInt16(x))); return 5
        case 0x36: // AND A, !abs+Y
            a = doAND(a, read(fetchWord() &+ UInt16(y))); return 5
        case 0x27: // AND A, [dp+X]
            a = doAND(a, read(addrIndirectX(fetchByte()))); return 6
        case 0x37: // AND A, [dp]+Y
            a = doAND(a, read(addrIndirectY(fetchByte()))); return 6
        case 0x29: // AND dp, dp
            let src = fetchByte(); let dst = fetchByte()
            let v = doAND(readDP(dst), readDP(src))
            writeDP(dst, value: v); return 6
        case 0x38: // AND dp, #imm
            let imm = fetchByte(); let dp = fetchByte()
            let v = doAND(readDP(dp), imm)
            writeDP(dp, value: v); return 5

        // ============================================================
        // EOR A, ...
        // ============================================================
        case 0x48: // EOR A, #imm
            a = doEOR(a, fetchByte()); return 2
        case 0x46: // EOR A, (X)
            a = doEOR(a, read(dpAddr(x))); return 3
        case 0x44: // EOR A, dp
            a = doEOR(a, readDP(fetchByte())); return 3
        case 0x54: // EOR A, dp+X
            a = doEOR(a, readDP(fetchByte() &+ x)); return 4
        case 0x45: // EOR A, !abs
            a = doEOR(a, read(fetchWord())); return 4
        case 0x55: // EOR A, !abs+X
            a = doEOR(a, read(fetchWord() &+ UInt16(x))); return 5
        case 0x56: // EOR A, !abs+Y
            a = doEOR(a, read(fetchWord() &+ UInt16(y))); return 5
        case 0x47: // EOR A, [dp+X]
            a = doEOR(a, read(addrIndirectX(fetchByte()))); return 6
        case 0x57: // EOR A, [dp]+Y
            a = doEOR(a, read(addrIndirectY(fetchByte()))); return 6
        case 0x49: // EOR dp, dp
            let src = fetchByte(); let dst = fetchByte()
            let v = doEOR(readDP(dst), readDP(src))
            writeDP(dst, value: v); return 6
        case 0x58: // EOR dp, #imm
            let imm = fetchByte(); let dp = fetchByte()
            let v = doEOR(readDP(dp), imm)
            writeDP(dp, value: v); return 5

        // ============================================================
        // CMP A, ...
        // ============================================================
        case 0x68: // CMP A, #imm
            doCMP(a, fetchByte()); return 2
        case 0x66: // CMP A, (X)
            doCMP(a, read(dpAddr(x))); return 3
        case 0x64: // CMP A, dp
            doCMP(a, readDP(fetchByte())); return 3
        case 0x74: // CMP A, dp+X
            doCMP(a, readDP(fetchByte() &+ x)); return 4
        case 0x65: // CMP A, !abs
            doCMP(a, read(fetchWord())); return 4
        case 0x75: // CMP A, !abs+X
            doCMP(a, read(fetchWord() &+ UInt16(x))); return 5
        case 0x76: // CMP A, !abs+Y
            doCMP(a, read(fetchWord() &+ UInt16(y))); return 5
        case 0x67: // CMP A, [dp+X]
            doCMP(a, read(addrIndirectX(fetchByte()))); return 6
        case 0x77: // CMP A, [dp]+Y
            doCMP(a, read(addrIndirectY(fetchByte()))); return 6
        case 0x69: // CMP dp, dp
            let src = fetchByte(); let dst = fetchByte()
            doCMP(readDP(dst), readDP(src)); return 6
        case 0x78: // CMP dp, #imm
            let imm = fetchByte(); let dp = fetchByte()
            doCMP(readDP(dp), imm); return 5

        // ============================================================
        // ADC A, ...
        // ============================================================
        case 0x88: // ADC A, #imm
            a = doADC(a, fetchByte()); return 2
        case 0x86: // ADC A, (X)
            a = doADC(a, read(dpAddr(x))); return 3
        case 0x84: // ADC A, dp
            a = doADC(a, readDP(fetchByte())); return 3
        case 0x94: // ADC A, dp+X
            a = doADC(a, readDP(fetchByte() &+ x)); return 4
        case 0x85: // ADC A, !abs
            a = doADC(a, read(fetchWord())); return 4
        case 0x95: // ADC A, !abs+X
            a = doADC(a, read(fetchWord() &+ UInt16(x))); return 5
        case 0x96: // ADC A, !abs+Y
            a = doADC(a, read(fetchWord() &+ UInt16(y))); return 5
        case 0x87: // ADC A, [dp+X]
            a = doADC(a, read(addrIndirectX(fetchByte()))); return 6
        case 0x97: // ADC A, [dp]+Y
            a = doADC(a, read(addrIndirectY(fetchByte()))); return 6
        case 0x89: // ADC dp, dp
            let src = fetchByte(); let dst = fetchByte()
            let v = doADC(readDP(dst), readDP(src))
            writeDP(dst, value: v); return 6
        case 0x98: // ADC dp, #imm
            let imm = fetchByte(); let dp = fetchByte()
            let v = doADC(readDP(dp), imm)
            writeDP(dp, value: v); return 5

        // ============================================================
        // SBC A, ...
        // ============================================================
        case 0xA8: // SBC A, #imm
            a = doSBC(a, fetchByte()); return 2
        case 0xA6: // SBC A, (X)
            a = doSBC(a, read(dpAddr(x))); return 3
        case 0xA4: // SBC A, dp
            a = doSBC(a, readDP(fetchByte())); return 3
        case 0xB4: // SBC A, dp+X
            a = doSBC(a, readDP(fetchByte() &+ x)); return 4
        case 0xA5: // SBC A, !abs
            a = doSBC(a, read(fetchWord())); return 4
        case 0xB5: // SBC A, !abs+X
            a = doSBC(a, read(fetchWord() &+ UInt16(x))); return 5
        case 0xB6: // SBC A, !abs+Y
            a = doSBC(a, read(fetchWord() &+ UInt16(y))); return 5
        case 0xA7: // SBC A, [dp+X]
            a = doSBC(a, read(addrIndirectX(fetchByte()))); return 6
        case 0xB7: // SBC A, [dp]+Y
            a = doSBC(a, read(addrIndirectY(fetchByte()))); return 6
        case 0xA9: // SBC dp, dp
            let src = fetchByte(); let dst = fetchByte()
            let v = doSBC(readDP(dst), readDP(src))
            writeDP(dst, value: v); return 6
        case 0xB8: // SBC dp, #imm
            let imm = fetchByte(); let dp = fetchByte()
            let v = doSBC(readDP(dp), imm)
            writeDP(dp, value: v); return 5

        // ============================================================
        // CMP X, ...
        // ============================================================
        case 0xC8: // CMP X, #imm
            doCMP(x, fetchByte()); return 2
        case 0x3E: // CMP X, dp
            doCMP(x, readDP(fetchByte())); return 3
        case 0x1E: // CMP X, !abs
            doCMP(x, read(fetchWord())); return 4

        // ============================================================
        // CMP Y, ...
        // ============================================================
        case 0xAD: // CMP Y, #imm
            doCMP(y, fetchByte()); return 2
        case 0x7E: // CMP Y, dp
            doCMP(y, readDP(fetchByte())); return 3
        case 0x5E: // CMP Y, !abs
            doCMP(y, read(fetchWord())); return 4

        // ============================================================
        // MOV A, ... (load)
        // ============================================================
        case 0xE8: // MOV A, #imm
            a = fetchByte(); setNZ(a); return 2
        case 0xE6: // MOV A, (X)
            a = read(dpAddr(x)); setNZ(a); return 3
        case 0xE4: // MOV A, dp
            a = readDP(fetchByte()); setNZ(a); return 3
        case 0xF4: // MOV A, dp+X
            a = readDP(fetchByte() &+ x); setNZ(a); return 4
        case 0xE5: // MOV A, !abs
            a = read(fetchWord()); setNZ(a); return 4
        case 0xF5: // MOV A, !abs+X
            a = read(fetchWord() &+ UInt16(x)); setNZ(a); return 5
        case 0xF6: // MOV A, !abs+Y
            a = read(fetchWord() &+ UInt16(y)); setNZ(a); return 5
        case 0xE7: // MOV A, [dp+X]
            a = read(addrIndirectX(fetchByte())); setNZ(a); return 6
        case 0xF7: // MOV A, [dp]+Y
            a = read(addrIndirectY(fetchByte())); setNZ(a); return 6
        case 0xBF: // MOV A, (X)+  (auto-increment)
            a = read(dpAddr(x)); x &+= 1; setNZ(a); return 4

        // ============================================================
        // MOV ..., A (store)
        // ============================================================
        case 0xC4: // MOV dp, A
            writeDP(fetchByte(), value: a); return 4
        case 0xD4: // MOV dp+X, A
            writeDP(fetchByte() &+ x, value: a); return 5
        case 0xC5: // MOV !abs, A
            write(fetchWord(), value: a); return 5
        case 0xD5: // MOV !abs+X, A
            write(fetchWord() &+ UInt16(x), value: a); return 6
        case 0xD6: // MOV !abs+Y, A
            write(fetchWord() &+ UInt16(y), value: a); return 6
        case 0xC6: // MOV (X), A
            write(dpAddr(x), value: a); return 4
        case 0xD7: // MOV [dp]+Y, A
            write(addrIndirectY(fetchByte()), value: a); return 7
        case 0xC7: // MOV [dp+X], A
            write(addrIndirectX(fetchByte()), value: a); return 7
        case 0xAF: // MOV (X)+, A (auto-increment)
            write(dpAddr(x), value: a); x &+= 1; return 4

        // ============================================================
        // MOV X, ... (load X)
        // ============================================================
        case 0xCD: // MOV X, #imm
            x = fetchByte(); setNZ(x); return 2
        case 0xF8: // MOV X, dp
            x = readDP(fetchByte()); setNZ(x); return 3
        case 0xF9: // MOV X, dp+Y
            x = readDP(fetchByte() &+ y); setNZ(x); return 4
        case 0xE9: // MOV X, !abs
            x = read(fetchWord()); setNZ(x); return 4

        // ============================================================
        // MOV ..., X (store X)
        // ============================================================
        case 0xD8: // MOV dp, X
            writeDP(fetchByte(), value: x); return 4
        case 0xD9: // MOV dp+Y, X
            writeDP(fetchByte() &+ y, value: x); return 5
        case 0xC9: // MOV !abs, X
            write(fetchWord(), value: x); return 5

        // ============================================================
        // MOV Y, ... (load Y)
        // ============================================================
        case 0x8D: // MOV Y, #imm
            y = fetchByte(); setNZ(y); return 2
        case 0xEB: // MOV Y, dp
            y = readDP(fetchByte()); setNZ(y); return 3
        case 0xFB: // MOV Y, dp+X
            y = readDP(fetchByte() &+ x); setNZ(y); return 4
        case 0xEC: // MOV Y, !abs
            y = read(fetchWord()); setNZ(y); return 4

        // ============================================================
        // MOV ..., Y (store Y)
        // ============================================================
        case 0xCB: // MOV dp, Y
            writeDP(fetchByte(), value: y); return 4
        case 0xDB: // MOV dp+X, Y
            writeDP(fetchByte() &+ x, value: y); return 5
        case 0xCC: // MOV !abs, Y
            write(fetchWord(), value: y); return 5

        // ============================================================
        // MOV register-register
        // ============================================================
        case 0x7D: // MOV A, X
            a = x; setNZ(a); return 2
        case 0xDD: // MOV A, Y
            a = y; setNZ(a); return 2
        case 0x5D: // MOV X, A
            x = a; setNZ(x); return 2
        case 0xFD: // MOV Y, A
            y = a; setNZ(y); return 2
        case 0x9D: // MOV X, SP
            x = sp; setNZ(x); return 2
        case 0xBD: // MOV SP, X
            sp = x; return 2

        // ============================================================
        // MOV dp, dp  and  MOV dp, #imm
        // ============================================================
        case 0xFA: // MOV dp, dp
            let src = fetchByte()
            let dst = fetchByte()
            writeDP(dst, value: readDP(src))
            return 5
        case 0x8F: // MOV dp, #imm
            let imm = fetchByte()
            let dp = fetchByte()
            writeDP(dp, value: imm)
            return 5

        // ============================================================
        // 16-bit MOV (YA pair)
        // ============================================================
        case 0xBA: // MOVW YA, dp
            let dp = fetchByte()
            let val = readDP16(dp)
            a = UInt8(val & 0xFF)
            y = UInt8(val >> 8)
            flagN = (y & 0x80) != 0
            flagZ = val == 0
            return 5
        case 0xDA: // MOVW dp, YA
            let dp = fetchByte()
            let val = UInt16(y) << 8 | UInt16(a)
            writeDP16(dp, value: val)
            return 5

        // ============================================================
        // 16-bit arithmetic
        // ============================================================
        case 0x3A: // INCW dp
            let dp = fetchByte()
            let val = readDP16(dp) &+ 1
            writeDP16(dp, value: val)
            flagN = (val & 0x8000) != 0
            flagZ = val == 0
            return 6
        case 0x1A: // DECW dp
            let dp = fetchByte()
            let val = readDP16(dp) &- 1
            writeDP16(dp, value: val)
            flagN = (val & 0x8000) != 0
            flagZ = val == 0
            return 6
        case 0x5A: // CMPW YA, dp
            let dp = fetchByte()
            let ya = UInt16(y) << 8 | UInt16(a)
            let val = readDP16(dp)
            doCPW(ya, val)
            return 4
        case 0x7A: // ADDW YA, dp
            let dp = fetchByte()
            let ya = UInt16(y) << 8 | UInt16(a)
            let val = readDP16(dp)
            let result = doADW(ya, val)
            a = UInt8(result & 0xFF)
            y = UInt8(result >> 8)
            return 5
        case 0x9A: // SUBW YA, dp
            let dp = fetchByte()
            let ya = UInt16(y) << 8 | UInt16(a)
            let val = readDP16(dp)
            let result = doSBW(ya, val)
            a = UInt8(result & 0xFF)
            y = UInt8(result >> 8)
            return 5

        // ============================================================
        // MUL / DIV
        // ============================================================
        case 0xCF: // MUL YA
            let result = UInt16(y) * UInt16(a)
            a = UInt8(result & 0xFF)
            y = UInt8(result >> 8)
            setNZ(y)
            return 9
        case 0x9E: // DIV YA, X
            let ya = UInt16(y) << 8 | UInt16(a)
            flagH = (y & 0x0F) >= (x & 0x0F)
            flagV = y >= x
            if Int(y) < (Int(x) << 1) {
                a = UInt8((ya / UInt16(x)) & 0x00FF)
                y = UInt8((ya % UInt16(x)) & 0x00FF)
            } else {
                let delta = Int(ya) - (Int(x) << 9)
                let denom = 0x100 - Int(x)
                a = UInt8(truncatingIfNeeded: 0xFF - (delta / denom))
                y = UInt8(truncatingIfNeeded: Int(x) + (delta % denom))
            }
            setNZ(a)
            return 12

        // ============================================================
        // ASL
        // ============================================================
        case 0x1C: // ASL A
            a = doASL(a); return 2
        case 0x0B: // ASL dp
            let dp = fetchByte()
            writeDP(dp, value: doASL(readDP(dp))); return 4
        case 0x1B: // ASL dp+X
            let dp = fetchByte() &+ x
            writeDP(dp, value: doASL(readDP(dp))); return 5
        case 0x0C: // ASL !abs
            let addr = fetchWord()
            write(addr, value: doASL(read(addr))); return 5

        // ============================================================
        // LSR
        // ============================================================
        case 0x5C: // LSR A
            a = doLSR(a); return 2
        case 0x4B: // LSR dp
            let dp = fetchByte()
            writeDP(dp, value: doLSR(readDP(dp))); return 4
        case 0x5B: // LSR dp+X
            let dp = fetchByte() &+ x
            writeDP(dp, value: doLSR(readDP(dp))); return 5
        case 0x4C: // LSR !abs
            let addr = fetchWord()
            write(addr, value: doLSR(read(addr))); return 5

        // ============================================================
        // ROL
        // ============================================================
        case 0x3C: // ROL A
            a = doROL(a); return 2
        case 0x2B: // ROL dp
            let dp = fetchByte()
            writeDP(dp, value: doROL(readDP(dp))); return 4
        case 0x3B: // ROL dp+X
            let dp = fetchByte() &+ x
            writeDP(dp, value: doROL(readDP(dp))); return 5
        case 0x2C: // ROL !abs
            let addr = fetchWord()
            write(addr, value: doROL(read(addr))); return 5

        // ============================================================
        // ROR
        // ============================================================
        case 0x7C: // ROR A
            a = doROR(a); return 2
        case 0x6B: // ROR dp
            let dp = fetchByte()
            writeDP(dp, value: doROR(readDP(dp))); return 4
        case 0x7B: // ROR dp+X
            let dp = fetchByte() &+ x
            writeDP(dp, value: doROR(readDP(dp))); return 5
        case 0x6C: // ROR !abs
            let addr = fetchWord()
            write(addr, value: doROR(read(addr))); return 5

        // ============================================================
        // INC
        // ============================================================
        case 0xBC: // INC A
            a &+= 1; setNZ(a); return 2
        case 0xAB: // INC dp
            let dp = fetchByte()
            let v = readDP(dp) &+ 1; writeDP(dp, value: v); setNZ(v); return 4
        case 0xBB: // INC dp+X
            let dp = fetchByte() &+ x
            let v = readDP(dp) &+ 1; writeDP(dp, value: v); setNZ(v); return 5
        case 0xAC: // INC !abs
            let addr = fetchWord()
            let v = read(addr) &+ 1; write(addr, value: v); setNZ(v); return 5
        case 0x3D: // INC X
            x &+= 1; setNZ(x); return 2
        case 0xFC: // INC Y
            y &+= 1; setNZ(y); return 2

        // ============================================================
        // DEC
        // ============================================================
        case 0x9C: // DEC A
            a &-= 1; setNZ(a); return 2
        case 0x8B: // DEC dp
            let dp = fetchByte()
            let v = readDP(dp) &- 1; writeDP(dp, value: v); setNZ(v); return 4
        case 0x9B: // DEC dp+X
            let dp = fetchByte() &+ x
            let v = readDP(dp) &- 1; writeDP(dp, value: v); setNZ(v); return 5
        case 0x8C: // DEC !abs
            let addr = fetchWord()
            let v = read(addr) &- 1; write(addr, value: v); setNZ(v); return 5
        case 0x1D: // DEC X
            x &-= 1; setNZ(x); return 2
        case 0xDC: // DEC Y
            y &-= 1; setNZ(y); return 2

        // ============================================================
        // Branches
        // ============================================================
        case 0x10: return branch(!flagN) // BPL
        case 0x30: return branch(flagN)  // BMI
        case 0x50: return branch(!flagV) // BVC
        case 0x70: return branch(flagV)  // BVS
        case 0x90: return branch(!flagC) // BCC
        case 0xB0: return branch(flagC)  // BCS
        case 0xD0: return branch(!flagZ) // BNE
        case 0xF0: return branch(flagZ)  // BEQ
        case 0x2F: // BRA (always)
            let rel = fetchByte()
            pc = UInt16(Int(pc) + Int(Int8(bitPattern: rel)))
            return 4

        // ============================================================
        // DBNZ
        // ============================================================
        case 0xFE: // DBNZ Y, rel
            let rel = fetchByte()
            y &-= 1
            if y != 0 {
                pc = UInt16(Int(pc) + Int(Int8(bitPattern: rel)))
                return 6
            }
            return 4
        case 0x6E: // DBNZ dp, rel
            let dp = fetchByte()
            let rel = fetchByte()
            let v = readDP(dp) &- 1
            writeDP(dp, value: v)
            if v != 0 {
                pc = UInt16(Int(pc) + Int(Int8(bitPattern: rel)))
                return 7
            }
            return 5

        // ============================================================
        // CBNE
        // ============================================================
        case 0x2E: // CBNE dp, rel
            let dp = fetchByte()
            let rel = fetchByte()
            if a != readDP(dp) {
                pc = UInt16(Int(pc) + Int(Int8(bitPattern: rel)))
                return 7
            }
            return 5
        case 0xDE: // CBNE dp+X, rel
            let dp = fetchByte()
            let rel = fetchByte()
            if a != readDP(dp &+ x) {
                pc = UInt16(Int(pc) + Int(Int8(bitPattern: rel)))
                return 8
            }
            return 6

        // ============================================================
        // Stack
        // ============================================================
        case 0x2D: push8(a); return 4           // PUSH A
        case 0x4D: push8(x); return 4           // PUSH X
        case 0x6D: push8(y); return 4           // PUSH Y
        case 0x0D: push8(psw); return 4         // PUSH PSW
        case 0xAE: a = pull8(); return 4  // POP A
        case 0xCE: x = pull8(); return 4  // POP X
        case 0xEE: y = pull8(); return 4  // POP Y
        case 0x8E: psw = pull8(); return 4       // POP PSW

        // ============================================================
        // Jumps / Calls / Returns
        // ============================================================
        case 0x5F: // JMP !abs
            pc = fetchWord(); return 3
        case 0x1F: // JMP [!abs+X]
            let addr = fetchWord() &+ UInt16(x)
            pc = read16(addr)
            return 6
        case 0x3F: // CALL !abs
            let addr = fetchWord()
            push16(pc)
            pc = addr
            return 8
        case 0x4F: // PCALL $FFxx
            let offset = fetchByte()
            push16(pc)
            pc = 0xFF00 | UInt16(offset)
            return 6
        case 0x6F: // RET
            pc = pull16()
            return 5
        case 0x7F: // RETI
            psw = pull8()
            pc = pull16()
            return 6
        case 0x0F: // BRK
            push16(pc)
            push8(psw)
            flagB = true
            flagI = false
            pc = read16(0xFFDE)
            return 8

        // ============================================================
        // Flags
        // ============================================================
        case 0x60: flagC = false; return 2   // CLRC
        case 0x80: flagC = true; return 2    // SETC
        case 0xED: flagC = !flagC; return 3  // NOTC
        case 0xE0: flagV = false; flagH = false; return 2  // CLRV
        case 0x20: flagP = false; return 2   // CLRP
        case 0x40: flagP = true; return 2    // SETP
        case 0xA0: flagI = true; return 3    // EI
        case 0xC0: flagI = false; return 3   // DI

        // ============================================================
        // XCN (swap nibbles of A)
        // ============================================================
        case 0x9F:
            a = (a >> 4) | (a << 4)
            setNZ(a)
            return 5

        // ============================================================
        // DAA / DAS
        // ============================================================
        case 0xDF: // DAA
            if flagC || a > 0x99 { a &+= 0x60; flagC = true }
            if flagH || (a & 0x0F) > 0x09 { a &+= 0x06 }
            setNZ(a)
            return 3
        case 0xBE: // DAS
            if !flagC || a > 0x99 { a &-= 0x60; flagC = false }
            if !flagH || (a & 0x0F) > 0x09 { a &-= 0x06 }
            setNZ(a)
            return 3

        // ============================================================
        // (X),(Y) operations
        // ============================================================
        case 0x19: // OR (X), (Y)
            let xv = read(dpAddr(x))
            let yv = read(dpAddr(y))
            let r = xv | yv
            write(dpAddr(x), value: r)
            setNZ(r)
            return 5
        case 0x39: // AND (X), (Y)
            let xv = read(dpAddr(x))
            let yv = read(dpAddr(y))
            let r = xv & yv
            write(dpAddr(x), value: r)
            setNZ(r)
            return 5
        case 0x59: // EOR (X), (Y)
            let xv = read(dpAddr(x))
            let yv = read(dpAddr(y))
            let r = xv ^ yv
            write(dpAddr(x), value: r)
            setNZ(r)
            return 5
        case 0x79: // CMP (X), (Y)
            let xv = read(dpAddr(x))
            let yv = read(dpAddr(y))
            doCMP(xv, yv)
            return 5
        case 0x99: // ADC (X), (Y)
            let xv = read(dpAddr(x))
            let yv = read(dpAddr(y))
            let r = doADC(xv, yv)
            write(dpAddr(x), value: r)
            return 5
        case 0xB9: // SBC (X), (Y)
            let xv = read(dpAddr(x))
            let yv = read(dpAddr(y))
            let r = doSBC(xv, yv)
            write(dpAddr(x), value: r)
            return 5

        // ============================================================
        // Bit operations with carry (OR1, AND1, EOR1, MOV1, NOT1)
        // ============================================================
        case 0x0A: // OR1 C, mem.bit
            let operand = fetchWord()
            let (addr, bit) = parseBitAddr(operand)
            let v = read(addr)
            if (v & (1 << bit)) != 0 { flagC = true }
            return 5
        case 0x2A: // OR1 C, /mem.bit
            let operand = fetchWord()
            let (addr, bit) = parseBitAddr(operand)
            let v = read(addr)
            if (v & (1 << bit)) == 0 { flagC = true }
            return 5
        case 0x4A: // AND1 C, mem.bit
            let operand = fetchWord()
            let (addr, bit) = parseBitAddr(operand)
            let v = read(addr)
            if (v & (1 << bit)) == 0 { flagC = false }
            return 4
        case 0x6A: // AND1 C, /mem.bit
            let operand = fetchWord()
            let (addr, bit) = parseBitAddr(operand)
            let v = read(addr)
            if (v & (1 << bit)) != 0 { flagC = false }
            return 4
        case 0x8A: // EOR1 C, mem.bit
            let operand = fetchWord()
            let (addr, bit) = parseBitAddr(operand)
            let v = read(addr)
            if (v & (1 << bit)) != 0 { flagC = !flagC }
            return 5
        case 0xAA: // MOV1 C, mem.bit
            let operand = fetchWord()
            let (addr, bit) = parseBitAddr(operand)
            let v = read(addr)
            flagC = (v & (1 << bit)) != 0
            return 4
        case 0xCA: // MOV1 mem.bit, C
            let operand = fetchWord()
            let (addr, bit) = parseBitAddr(operand)
            var v = read(addr)
            if flagC {
                v |= (1 << bit)
            } else {
                v &= ~(1 << bit)
            }
            write(addr, value: v)
            return 6
        case 0xEA: // NOT1 mem.bit
            let operand = fetchWord()
            let (addr, bit) = parseBitAddr(operand)
            var v = read(addr)
            v ^= (1 << bit)
            write(addr, value: v)
            return 5

        // ============================================================
        // TSET1 / TCLR1
        // ============================================================
        case 0x0E: // TSET1 !abs
            let addr = fetchWord()
            let v = read(addr)
            setNZ(a &- v)  // flags based on A - val (confirmed by bsnes reference)
            write(addr, value: v | a)
            return 6
        case 0x4E: // TCLR1 !abs
            let addr = fetchWord()
            let v = read(addr)
            setNZ(a &- v)  // flags based on A - val (confirmed by bsnes reference)
            write(addr, value: v & ~a)
            return 6

        // ============================================================
        // SLEEP / STOP
        // ============================================================
        case 0xEF: // SLEEP
            sleeping = true
            return 3
        case 0xFF: // STOP
            stopped = true
            return 3

        // ============================================================
        // Unused / catch-all
        // ============================================================
        default:
            // Unknown opcode — treat as NOP
            return 2
            }
        }()

        return cycles
    }
}

// MARK: - Save state

extension SPC700 {
    func serialize(into w: inout StateWriter) {
        w.put(a); w.put(x); w.put(y); w.put(sp); w.put(pc); w.put(psw)
        w.put(ram); w.put(portsFromCPU); w.put(portsToCPU); w.put(dspAddr)
        w.put(timerEnabled); w.put(timerDivisor); w.put(timerCounter); w.put(timerInternal)
        w.put(timerStage1); w.put(timerLine); w.put(timerStage2)
        w.put(timersDisable); w.put(timersEnable)
        w.put(bootRomEnabled); w.put(cycles); w.put(stopped); w.put(sleeping)
    }

    func deserialize(from r: inout StateReader) throws {
        a = try r.u8(); x = try r.u8(); y = try r.u8(); sp = try r.u8(); pc = try r.u16(); psw = try r.u8()
        ram = try r.bytes8(count: ram.count)
        portsFromCPU = try r.bytes8(count: 4); portsToCPU = try r.bytes8(count: 4); dspAddr = try r.u8()
        timerEnabled = try r.bools(); timerDivisor = try r.bytes8(count: 3)
        timerCounter = try r.bytes8(count: 3); timerInternal = try r.u16s()
        timerStage1 = try r.bools(); timerLine = try r.bools(); timerStage2 = try r.ints()
        timersDisable = try r.bool(); timersEnable = try r.bool()
        bootRomEnabled = try r.bool(); cycles = try r.int(); stopped = try r.bool(); sleeping = try r.bool()
        guard timerEnabled.count == 3, timerInternal.count == 3, timerStage1.count == 3,
              timerLine.count == 3, timerStage2.count == 3 else { throw StateReader.Error.sizeMismatch }
    }
}
