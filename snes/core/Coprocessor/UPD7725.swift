// NEC uPD7725 / uPD77C25 — port of gufranco/nec-upd7725-96050-python (MIT).
// One instruction = one clock. DSP-1/2/3/4 are this CPU with different mask ROMs.

import Foundation

final class UPD7725 {

    static let wordMask = 0xFFFF
    static let sign = 0x8000
    static let resetCycles = 4
    static let interruptVector = 0x100
    static let formShift = 22
    static let farHalf = 0x2000
    static let bankShift = 11
    static let scratchFarHalf = 0x40
    static let statusKept = 0x907C
    static let statusTaken = 0xFFFF & ~0x907C
    static let multiplyShift = 15
    static let pointerLow = 0x0F
    static let pointerHigh = 0xF0

    struct Model {
        let name: String
        let counterBits: Int
        let tableBits: Int
        let pointerBits: Int
        let stackLevels: Int

        var programWords: Int { 1 << counterBits }
        var tableWords: Int { 1 << tableBits }
        var scratchWords: Int { 1 << pointerBits }

        static let upd7725 = Model(
            name: "upd7725",
            counterBits: 11,
            tableBits: 10,
            pointerBits: 8,
            stackLevels: 4
        )
    }

    struct Flags {
        var ov0 = false
        var ov1 = false
        var z = false
        var c = false
        var s0 = false
        var s1 = false

        mutating func recordResult(_ result: Int) {
            z = result == 0
            s0 = (result & UPD7725.sign) != 0
            if !ov1 { s1 = s0 }
        }

        mutating func recordLogic() {
            ov0 = false
            ov1 = false
            c = false
        }

        mutating func recordAddition(left: Int, right: Int, result: Int, adding: Bool) {
            let overflow = (left ^ result) & (right ^ (adding ? result : left))
            let held = ov1
            ov0 = (overflow & UPD7725.sign) != 0
            ov1 = (ov0 && held) ? (s0 == s1) : (ov0 || held)
            let carries = left ^ right ^ result
            c = ((carries ^ overflow) & UPD7725.sign) != 0
        }

        mutating func recordRightShift(_ before: Int) {
            ov0 = false
            ov1 = false
            c = (before & 1) != 0
        }

        mutating func recordLeftShift(_ before: Int) {
            ov0 = false
            ov1 = false
            c = ((before >> 15) & 1) != 0
        }
    }

    struct Status {
        var p0 = false
        var p1 = false
        var ei = false
        var sic = false
        var soc = false
        var drc = false
        var dma = false
        var usf0 = false
        var usf1 = false
        var rqm = false
        var drs = false
        var siack = false
        var soack = false

        mutating func assign(_ word: Int) {
            p0 = (word >> 0 & 1) != 0
            p1 = (word >> 1 & 1) != 0
            ei = (word >> 7 & 1) != 0
            sic = (word >> 8 & 1) != 0
            soc = (word >> 9 & 1) != 0
            drc = (word >> 10 & 1) != 0
            dma = (word >> 11 & 1) != 0
            usf0 = (word >> 13 & 1) != 0
            usf1 = (word >> 14 & 1) != 0
            rqm = (word >> 15 & 1) != 0
            drs = (word >> 12 & 1) != 0
        }

        var word: Int {
            var value =
                (p0 ? 1 : 0) << 0
                | (p1 ? 1 : 0) << 1
                | (ei ? 1 : 0) << 7
                | (sic ? 1 : 0) << 8
                | (soc ? 1 : 0) << 9
                | (drc ? 1 : 0) << 10
                | (dma ? 1 : 0) << 11
                | (usf0 ? 1 : 0) << 13
                | (usf1 ? 1 : 0) << 14
                | (rqm ? 1 : 0) << 15
            if drs && !drc { value |= 1 << 12 }
            return value
        }
    }

    final class Registers {
        let counterMask: Int
        let tableMask: Int
        let pointerMask: Int
        let stackMask: Int
        var stack: [Int]
        private var pcStorage = 0
        private var rpStorage = 0
        private var dpStorage = 0
        private var spStorage = 0
        private var kStorage: Int16 = 0
        private var lStorage: Int16 = 0
        private var mStorage: Int16 = 0
        private var nStorage: Int16 = 0
        private var aStorage: Int16 = 0
        private var bStorage: Int16 = 0
        var si = 0
        var so = 0
        var tr = 0
        var trb = 0
        var dr = 0
        var sr = Status()

        /// Zera todo o estado do processador. O reset do uPD7725 não preserva
        /// acumuladores, ponteiros nem flags.
        func clear() {
            pc = 0; rp = 0; dp = 0; sp = 0
            k = 0; l = 0; m = 0; n = 0; a = 0; b = 0
            si = 0; so = 0; tr = 0; trb = 0; dr = 0
            sr = Status()
            for i in 0..<stack.count { stack[i] = 0 }
        }

        init(model: Model) {
            counterMask = (1 << model.counterBits) - 1
            tableMask = (1 << model.tableBits) - 1
            pointerMask = (1 << model.pointerBits) - 1
            stackMask = model.stackLevels - 1
            stack = [Int](repeating: 0, count: model.stackLevels)
        }

        var pc: Int {
            get { pcStorage }
            set { pcStorage = newValue & counterMask }
        }
        var rp: Int {
            get { rpStorage }
            set { rpStorage = newValue & tableMask }
        }
        var dp: Int {
            get { dpStorage }
            set { dpStorage = newValue & pointerMask }
        }
        var sp: Int {
            get { spStorage }
            set { spStorage = newValue & stackMask }
        }
        var k: Int {
            get { Int(kStorage) }
            set { kStorage = Int16(truncatingIfNeeded: newValue) }
        }
        var l: Int {
            get { Int(lStorage) }
            set { lStorage = Int16(truncatingIfNeeded: newValue) }
        }
        var m: Int {
            get { Int(mStorage) }
            set { mStorage = Int16(truncatingIfNeeded: newValue) }
        }
        var n: Int {
            get { Int(nStorage) }
            set { nStorage = Int16(truncatingIfNeeded: newValue) }
        }
        var a: Int {
            get { Int(aStorage) }
            set { aStorage = Int16(truncatingIfNeeded: newValue) }
        }
        var b: Int {
            get { Int(bStorage) }
            set { bStorage = Int16(truncatingIfNeeded: newValue) }
        }

        func wordK() -> Int { Int(UInt16(bitPattern: kStorage)) }
        func wordL() -> Int { Int(UInt16(bitPattern: lStorage)) }
        func wordM() -> Int { Int(UInt16(bitPattern: mStorage)) }
        func wordN() -> Int { Int(UInt16(bitPattern: nStorage)) }
        func wordA() -> Int { Int(UInt16(bitPattern: aStorage)) }
        func wordB() -> Int { Int(UInt16(bitPattern: bStorage)) }
    }

    let model: Model
    let registers: Registers
    var program: [UInt32]
    var table: [UInt16]
    var scratch: [UInt16]
    var flagsA = Flags()
    var flagsB = Flags()
    var cycles = 0
    var steps = 0

    init(model: Model = .upd7725) {
        self.model = model
        registers = Registers(model: model)
        program = [UInt32](repeating: 0, count: model.programWords)
        table = [UInt16](repeating: 0, count: model.tableWords)
        scratch = [UInt16](repeating: 0, count: model.scratchWords)
    }

    func loadFirmware(programBytes: Data, tableBytes: Data) {
        let programCount = programBytes.count / 3
        programBytes.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for at in 0..<programCount {
                let base = at * 3
                program[at] = (UInt32(bytes[base]) << 16)
                    | (UInt32(bytes[base + 1]) << 8)
                    | UInt32(bytes[base + 2])
            }
        }
        let tableCount = tableBytes.count / 2
        tableBytes.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for at in 0..<tableCount {
                let base = at * 2
                table[at] = (UInt16(bytes[base]) << 8) | UInt16(bytes[base + 1])
            }
        }
    }

    func reset() {
        registers.clear()
        flagsA = Flags()
        flagsB = Flags()
        for i in 0..<scratch.count { scratch[i] = 0 }
        steps = 0
        for _ in 0..<Self.resetCycles { spend() }
    }

    func spend() { cycles += 1 }

    @discardableResult
    func step() -> Int {
        let opcode = Int(program[registers.pc])
        registers.pc += 1
        let form = opcode >> Self.formShift
        switch form {
        case 0: operate(opcode)
        case 1:
            operate(opcode)
            registers.sp -= 1
            registers.pc = registers.stack[registers.sp]
        case 2: jump(opcode)
        default: load(opcode)
        }
        multiply()
        let before = cycles
        spend()
        steps += 1
        return cycles - before
    }

    func run(steps count: Int) {
        for _ in 0..<count { step() }
    }

    private func multiply() {
        let product = Int64(registers.k) * Int64(registers.l)
        registers.m = Int(product >> Int64(Self.multiplyShift))
        registers.n = Int(product << 1)
    }

    private func operate(_ opcode: Int) {
        let pselect = opcode >> 20 & 0x3
        let alu = opcode >> 16 & 0xF
        let asl = opcode >> 15 & 0x1
        let dpl = opcode >> 13 & 0x3
        let dphm = opcode >> 9 & 0xF
        let rpdcr = opcode >> 8 & 0x1
        let source = opcode >> 4 & 0xF
        let destination = opcode & 0xF
        let moving = read(source)
        // A ALU sempre roda, mesmo quando o destino é o próprio acumulador:
        // pular o cálculo também pularia a atualização das flags, e o firmware
        // do DSP-1 desvia com base nelas. A escrita do destino vem depois e
        // naturalmente sobrepõe o valor do acumulador quando coincidem.
        if alu != 0 {
            compute(alu: alu, pselect: pselect, asl: asl, moving: moving)
        }
        load(moving << 6 | destination)
        if destination != 4 { stepPointer(dpl: dpl, dphm: dphm) }
        if destination != 5 && rpdcr != 0 { registers.rp -= 1 }
    }

    private func jump(_ opcode: Int) {
        let branch = opcode >> 13 & 0x1FF
        let address = opcode >> 2 & 0x7FF
        let bank = opcode & 0x3
        let target = (registers.pc & Self.farHalf | bank << Self.bankShift | address) & 0x3FFF
        switch branch {
        case 0x000:
            registers.pc = registers.so
        case 0x100:
            registers.pc = target & ~Self.farHalf
        case 0x101:
            registers.pc = target | Self.farHalf
        case 0x140, 0x141:
            registers.stack[registers.sp] = registers.pc
            registers.sp += 1
            registers.pc = branch == 0x141 ? (target | Self.farHalf) : (target & ~Self.farHalf)
        default:
            if branchTaken(branch) { registers.pc = target }
        }
    }

    private func branchTaken(_ branch: Int) -> Bool {
        switch branch {
        case 0x080: return !flagsA.c
        case 0x082: return flagsA.c
        case 0x084: return !flagsB.c
        case 0x086: return flagsB.c
        case 0x088: return !flagsA.z
        case 0x08A: return flagsA.z
        case 0x08C: return !flagsB.z
        case 0x08E: return flagsB.z
        case 0x090: return !flagsA.ov0
        case 0x092: return flagsA.ov0
        case 0x094: return !flagsB.ov0
        case 0x096: return flagsB.ov0
        case 0x098: return !flagsA.ov1
        case 0x09A: return flagsA.ov1
        case 0x09C: return !flagsB.ov1
        case 0x09E: return flagsB.ov1
        case 0x0A0: return !flagsA.s0
        case 0x0A2: return flagsA.s0
        case 0x0A4: return !flagsB.s0
        case 0x0A6: return flagsB.s0
        case 0x0A8: return !flagsA.s1
        case 0x0AA: return flagsA.s1
        case 0x0AC: return !flagsB.s1
        case 0x0AE: return flagsB.s1
        case 0x0B0: return (registers.dp & Self.pointerLow) == 0
        case 0x0B1: return (registers.dp & Self.pointerLow) != 0
        case 0x0B2: return (registers.dp & Self.pointerLow) == Self.pointerLow
        case 0x0B3: return (registers.dp & Self.pointerLow) != Self.pointerLow
        case 0x0B4: return !registers.sr.siack
        case 0x0B6: return registers.sr.siack
        case 0x0B8: return !registers.sr.soack
        case 0x0BA: return registers.sr.soack
        case 0x0BC: return !registers.sr.rqm
        case 0x0BE: return registers.sr.rqm
        default: return false
        }
    }

    private func read(_ source: Int) -> Int {
        switch source {
        case 0: return registers.trb
        case 1: return registers.wordA()
        case 2: return registers.wordB()
        case 3: return registers.tr
        case 4: return registers.dp
        case 5: return registers.rp
        case 6: return Int(table[registers.rp])
        case 7: return Self.sign - (flagsA.s1 ? 1 : 0)
        case 8:
            registers.sr.rqm = true
            return registers.dr
        case 9: return registers.dr
        case 10: return registers.sr.word
        case 11, 12: return registers.si
        case 13: return registers.wordK()
        case 14: return registers.wordL()
        default: return Int(scratch[registers.dp])
        }
    }

    private func compute(alu: Int, pselect: Int, asl: Int, moving: Int) {
        let right: Int
        switch pselect {
        case 0: right = Int(scratch[registers.dp])
        case 1: right = moving
        case 2: right = registers.wordM()
        default: right = registers.wordN()
        }
        let left: Int
        var flags: Flags
        let carry: Int
        if asl != 0 {
            left = registers.wordB()
            flags = flagsB
            carry = flagsA.c ? 1 : 0
        } else {
            left = registers.wordA()
            flags = flagsA
            carry = flagsB.c ? 1 : 0
        }
        let (result, flagRight) = apply(alu: alu, left: left, right: right, carry: carry)
        flags.recordResult(result)
        switch alu {
        case 1, 2, 3, 10, 13, 14, 15:
            flags.recordLogic()
        case 4, 5, 6, 7, 8, 9:
            flags.recordAddition(left: left, right: flagRight, result: result, adding: (alu & 1) != 0)
        case 11:
            flags.recordRightShift(left)
        default:
            flags.recordLeftShift(left)
        }
        if asl != 0 {
            registers.b = result
            flagsB = flags
        } else {
            registers.a = result
            flagsA = flags
        }
    }

    private func load(_ opcode: Int) {
        let value = opcode >> 6 & Self.wordMask
        let destination = opcode & 0xF
        switch destination {
        case 0: return
        case 1: registers.a = value
        case 2: registers.b = value
        case 3: registers.tr = value
        case 4: registers.dp = value
        case 5: registers.rp = value
        case 6:
            registers.dr = value
            registers.sr.rqm = true
        case 7:
            registers.sr.assign(registers.sr.word & Self.statusKept | value & Self.statusTaken)
        case 8, 9: registers.so = value
        case 10: registers.k = value
        case 11:
            registers.k = value
            registers.l = Int(table[registers.rp])
        case 12:
            registers.l = value
            registers.k = Int(scratch[registers.dp | Self.scratchFarHalf])
        case 13: registers.l = value
        case 14: registers.trb = value
        default: scratch[registers.dp] = UInt16(value & Self.wordMask)
        }
    }

    private func stepPointer(dpl: Int, dphm: Int) {
        var pointer = registers.dp
        switch dpl {
        case 1: pointer = (pointer & Self.pointerHigh) + ((pointer + 1) & Self.pointerLow)
        case 2: pointer = (pointer & Self.pointerHigh) + ((pointer - 1) & Self.pointerLow)
        case 3: pointer = pointer & Self.pointerHigh
        default: break
        }
        if dpl != 0 { registers.dp = pointer }
        registers.dp = registers.dp ^ (dphm << 4)
    }

    private func apply(alu: Int, left: Int, right: Int, carry: Int) -> (Int, Int) {
        switch alu {
        case 1: return ((left | right) & Self.wordMask, right)
        case 2: return (left & right & Self.wordMask, right)
        case 3: return ((left ^ right) & Self.wordMask, right)
        case 4: return ((left - right) & Self.wordMask, right)
        case 5: return ((left + right) & Self.wordMask, right)
        case 6: return ((left - right - carry) & Self.wordMask, right)
        case 7: return ((left + right + carry) & Self.wordMask, right)
        case 8: return ((left - 1) & Self.wordMask, 1)
        case 9: return ((left + 1) & Self.wordMask, 1)
        case 10: return ((~left) & Self.wordMask, right)
        case 11: return ((left >> 1 | left & Self.sign) & Self.wordMask, right)
        case 12: return ((left << 1 | carry) & Self.wordMask, right)
        case 13: return ((left << 2 | 3) & Self.wordMask, right)
        case 14: return ((left << 4 | 15) & Self.wordMask, right)
        default: return ((left << 8 | left >> 8) & Self.wordMask, right)
        }
    }

    // MARK: - Host ports (byte-wide SNES data / status)

    var asking: Bool { registers.sr.rqm }

    func readStatus() -> UInt8 {
        UInt8((registers.sr.word >> 8) & 0xFF)
    }

    func readData() -> UInt8 {
        if registers.sr.drc {
            registers.sr.rqm = false
            return UInt8(registers.dr & 0xFF)
        }
        if !registers.sr.drs {
            registers.sr.drs = true
            return UInt8(registers.dr & 0xFF)
        }
        registers.sr.rqm = false
        registers.sr.drs = false
        return UInt8((registers.dr >> 8) & 0xFF)
    }

    func writeData(_ value: UInt8) {
        let byte = Int(value)
        if registers.sr.drc {
            registers.sr.rqm = false
            registers.dr = registers.dr & 0xFF00 | byte
            return
        }
        if !registers.sr.drs {
            registers.sr.drs = true
            registers.dr = registers.dr & 0xFF00 | byte
            return
        }
        registers.sr.rqm = false
        registers.sr.drs = false
        registers.dr = byte << 8 | registers.dr & 0x00FF
    }
}
