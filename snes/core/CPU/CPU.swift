//
//  CPU.swift
//  snes
//
//  Created by Arilson Simplicio on 14/05/25.
//
import Foundation

class CPU65816 {
    // Registradores
    var a: UInt16 = 0      // Acumulador
    var x: UInt16 = 0      // Índice X
    var y: UInt16 = 0      // Índice Y
    var s: UInt16 = 0x01FF // Stack Pointer
    var d: UInt16 = 0      // Direct Page
    var db: UInt8 = 0      // Data Bank
    var pb: UInt8 = 0      // Program Bank
    var pc: UInt16 = 0     // Program Counter
    var p: UInt8 = 0x34    // Status Register
    
    // Flags do Status Register
    enum StatusFlag: UInt8 {
        case carry = 0x01      // C
        case zero = 0x02       // Z
        case irqDisable = 0x04 // I
        case decimal = 0x08    // D
        case index = 0x10      // X (0=16-bit, 1=8-bit)
        case memory = 0x20     // M (0=16-bit, 1=8-bit)
        case overflow = 0x40   // V
        case negative = 0x80   // N
    }
    
    // Referência para memória
    private var memory: MemoryBus
    
    // Estado do processador
    var cycles: Int = 0
    var isEmulationMode: Bool = true
    
    init(memory: MemoryBus) {
        self.memory = memory
        reset()
    }
    private var instructionCount: Int = 0
    // Reset do CPU
    func reset() {
        // Limpa registradores primeiro
        a = 0
        x = 0
        y = 0
        d = 0
        db = 0
        
        // Estado inicial
        s = 0x01FF
        p = 0x34  // IRQ desabilitado, modo 8-bit
        isEmulationMode = true
        pb = 0
        
        // Lê vetor de reset do banco 0
        pc = memory.read16(0x00FFFC)
        
        print("=== CPU Reset ===")
        print("PC inicial: \(String(format: "$%02X:%04X", pb, pc))")
        print("Vetor de reset lido de $00FFFC: \(String(format: "$%04X", pc))")
        
        // Debug: vamos ver o que tem no endereço do reset
        print("Primeiros 16 bytes no PC inicial:")
        for i in 0..<16 {
            let offset = Int(pc) + i
            if offset <= 0xFFFF {
                let address = UInt32(pb) << 16 | UInt32(offset)
                let byte = memory.read8(address)
                print("  [\(String(format: "$%06X", address))] = \(String(format: "$%02X", byte))")
            }
        }
        print("================")
    }
    
    // Executa um passo
    func step() {
        let address = UInt32(pb) << 16 | UInt32(pc)
        let opcode = memory.read8(address)
        
        instructionCount += 1
        
        // Debug mais detalhado
        print("[\(instructionCount)] PC: \(String(format: "$%02X:%04X", pb, pc)) Opcode: \(String(format: "$%02X", opcode))")
        
        // Incrementa PC com overflow correto
        pc = (pc &+ 1) & 0xFFFF
        
        executeInstruction(opcode)
    }
    
    // Busca próximo byte
    private func fetchByte() -> UInt8 {
        let address = UInt32(pb) << 16 | UInt32(pc)
        let byte = memory.read8(address)
        print("fetchByte em PC: \(String(format: "$%04X", pc)) = \(String(format: "$%02X", byte))")
        
        // Incrementa PC com overflow correto
        pc = (pc &+ 1) & 0xFFFF
        
        return byte
    }
    
    // Busca próxima word
    private func fetchWord() -> UInt16 {
        let low = UInt16(fetchByte())
        let high = UInt16(fetchByte())
        return (high << 8) | low
    }
    
    // Verifica flag
    func getFlag(_ flag: StatusFlag) -> Bool {
        return (p & flag.rawValue) != 0
    }
    
    // Define flag
    func setFlag(_ flag: StatusFlag, _ value: Bool) {
        if value {
            p |= flag.rawValue
        } else {
            p &= ~flag.rawValue
        }
    }
    
    // Atualiza flags N e Z baseado no valor
    private func updateNZ(_ value: UInt16) {
        if getFlag(.memory) {
            // Modo 8-bit
            setFlag(.zero, (value & 0xFF) == 0)
            setFlag(.negative, (value & 0x80) != 0)
        } else {
            // Modo 16-bit
            setFlag(.zero, value == 0)
            setFlag(.negative, (value & 0x8000) != 0)
        }
    }
    
    // Executa instrução
    private func executeInstruction(_ opcode: UInt8) {
        switch opcode {
        case 0xB1: // LDA (dp),Y
            let addr = getIndirectIndexedAddress()
            a = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            updateNZ(a)
        case 0xA3: // LDA sr,S
            let addr = getStackRelativeAddress()
            a = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            updateNZ(a)
        case 0xB3: // LDA (sr,S),Y
            let addr = getStackRelativeIndirectIndexedAddress()
            a = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            updateNZ(a)
            
            // Store A
        case 0x85: // STA dp
            let addr = getDirectPageAddress()
            if getFlag(.memory) {
                memory.write8(addr, UInt8(a & 0xFF))
            } else {
                memory.write16(addr, a)
            }
        case 0x95: // STA dp,X
            let addr = getDirectPageXAddress()
            if getFlag(.memory) {
                memory.write8(addr, UInt8(a & 0xFF))
            } else {
                memory.write16(addr, a)
            }
        case 0x8D: STA_absolute()           // STA abs
        case 0x9D: // STA abs,X
            let addr = getAbsoluteXAddress()
            if getFlag(.memory) {
                memory.write8(addr, UInt8(a & 0xFF))
            } else {
                memory.write16(addr, a)
            }
        case 0x99: // STA abs,Y
            let addr = getAbsoluteYAddress()
            if getFlag(.memory) {
                memory.write8(addr, UInt8(a & 0xFF))
            } else {
                memory.write16(addr, a)
            }
        case 0x8F: // STA long
            let addr = fetchLong()
            if getFlag(.memory) {
                memory.write8(addr, UInt8(a & 0xFF))
            } else {
                memory.write16(addr, a)
            }
        case 0x9F: // STA long,X
            let addr = fetchLong() + UInt32(x)
            if getFlag(.memory) {
                memory.write8(addr, UInt8(a & 0xFF))
            } else {
                memory.write16(addr, a)
            }
        case 0x87: // STA [dp]
            let addr = getIndirectLongAddress()
            if getFlag(.memory) {
                memory.write8(addr, UInt8(a & 0xFF))
            } else {
                memory.write16(addr, a)
            }
        case 0x97: // STA [dp],Y
            let addr = getIndirectIndexedLongAddress()
            if getFlag(.memory) {
                memory.write8(addr, UInt8(a & 0xFF))
            } else {
                memory.write16(addr, a)
            }
        case 0x81: // STA (dp,X)
            let addr = getIndexedIndirectAddress()
            if getFlag(.memory) {
                memory.write8(addr, UInt8(a & 0xFF))
            } else {
                memory.write16(addr, a)
            }
        case 0x91: // STA (dp),Y
            let addr = getIndirectIndexedAddress()
            if getFlag(.memory) {
                memory.write8(addr, UInt8(a & 0xFF))
            } else {
                memory.write16(addr, a)
            }
        case 0x83: // STA sr,S
            let addr = getStackRelativeAddress()
            if getFlag(.memory) {
                memory.write8(addr, UInt8(a & 0xFF))
            } else {
                memory.write16(addr, a)
            }
        case 0x93: // STA (sr,S),Y
            let addr = getStackRelativeIndirectIndexedAddress()
            if getFlag(.memory) {
                memory.write8(addr, UInt8(a & 0xFF))
            } else {
                memory.write16(addr, a)
            }
            
            // Load/Store X
        case 0xA2: LDX_immediate()          // LDX #
        case 0xA6: // LDX dp
            let addr = getDirectPageAddress()
            x = getFlag(.index) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            updateNZ(x)
        case 0xB6: // LDX dp,Y
            let addr = getDirectPageYAddress()
            x = getFlag(.index) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            updateNZ(x)
        case 0xAE: // LDX abs
            let addr = getAbsoluteAddress()
            x = getFlag(.index) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            updateNZ(x)
        case 0xBE: // LDX abs,Y
            let addr = getAbsoluteYAddress()
            x = getFlag(.index) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            updateNZ(x)
            
        case 0x86: // STX dp
            let addr = getDirectPageAddress()
            if getFlag(.index) {
                memory.write8(addr, UInt8(x & 0xFF))
            } else {
                memory.write16(addr, x)
            }
        case 0x96: // STX dp,Y
            let addr = getDirectPageYAddress()
            if getFlag(.index) {
                memory.write8(addr, UInt8(x & 0xFF))
            } else {
                memory.write16(addr, x)
            }
        case 0x8E: STX_absolute()           // STX abs
            
            // Load/Store Y
        case 0xA0: LDY_immediate()          // LDY #
        case 0xA4: // LDY dp
            let addr = getDirectPageAddress()
            y = getFlag(.index) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            updateNZ(y)
        case 0xB4: // LDY dp,X
            let addr = getDirectPageXAddress()
            y = getFlag(.index) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            updateNZ(y)
        case 0xAC: // LDY abs
            let addr = getAbsoluteAddress()
            y = getFlag(.index) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            updateNZ(y)
        case 0xBC: // LDY abs,X
            let addr = getAbsoluteXAddress()
            y = getFlag(.index) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            updateNZ(y)
            
        case 0x84: // STY dp
            let addr = getDirectPageAddress()
            if getFlag(.index) {
                memory.write8(addr, UInt8(y & 0xFF))
            } else {
                memory.write16(addr, y)
            }
        case 0x94: // STY dp,X
            let addr = getDirectPageXAddress()
            if getFlag(.index) {
                memory.write8(addr, UInt8(y & 0xFF))
            } else {
                memory.write16(addr, y)
            }
        case 0x8C: STY_absolute()           // STY abs
            
            // STZ - Store Zero
        case 0x64: // STZ dp
            let addr = getDirectPageAddress()
            if getFlag(.memory) {
                memory.write8(addr, 0)
            } else {
                memory.write16(addr, 0)
            }
        case 0x74: // STZ dp,X
            let addr = getDirectPageXAddress()
            if getFlag(.memory) {
                memory.write8(addr, 0)
            } else {
                memory.write16(addr, 0)
            }
        case 0x9C: STZ_absolute()           // STZ abs
        case 0x9E: // STZ abs,X
            let addr = getAbsoluteXAddress()
            if getFlag(.memory) {
                memory.write8(addr, 0)
            } else {
                memory.write16(addr, 0)
            }
            
            // Transfer Operations
        case 0xAA: TAX()                    // TAX
        case 0xA8: TAY()                    // TAY
        case 0x8A: TXA()                    // TXA
        case 0x98: TYA()                    // TYA
        case 0xBA: TSX()                    // TSX
        case 0x9A: TXS()                    // TXS
        case 0x5B: // TCD
            d = a
            updateNZ16(d)
        case 0x7B: // TDC
            a = d
            updateNZ16(a)
        case 0x1B: // TCS
            s = a
            if isEmulationMode {
                s = (s & 0xFF) | 0x0100
            }
        case 0x3B: // TSC
            a = s
            updateNZ16(a)
        case 0xEB: // XBA
            a = ((a & 0xFF) << 8) | ((a >> 8) & 0xFF)
            updateNZ8(UInt8(a & 0xFF))
        case 0x9B: // TXY
            if getFlag(.index) {
                y = x & 0xFF
                updateNZ8(UInt8(y))
            } else {
                y = x
                updateNZ16(y)
            }
        case 0xBB: // TYX
            if getFlag(.index) {
                x = y & 0xFF
                updateNZ8(UInt8(x))
            } else {
                x = y
                updateNZ16(x)
            }
        case 0x02: // COP
            let signature = fetchByte()
            pushByte(pb)
            pushWord(pc)
            pushByte(p)
            setFlag(.irqDisable, true)
            pb = 0
            pc = memory.read16(0xFFE4)  // COP vector

        case 0x42: // WDM - William D. Mensch (criador do 65816)
            // Opcode reservado, funciona como NOP de 2 bytes
            let _ = fetchByte()  // Descarta o operando
            cycles += 2

        case 0xCB: // WAI - Wait for Interrupt
            // Por enquanto, só incrementa ciclos
            // Em uma implementação completa, pausaria até uma interrupção
            cycles += 3

        case 0xDB: // STP - Stop the Clock
            // Para o processador até reset
            // Por enquanto, apenas incrementa ciclos
            cycles += 3
        case 0x00: // BRK
            print("BRK encontrado no PC: \(String(format: "$%02X:%04X", pb, pc - 1))")
            pushByte(pb)
            pushWord(pc + 1)
            pushByte(p | 0x10)  // Set B flag
            
            setFlag(.irqDisable, true)
            
            if isEmulationMode {
                pc = memory.read16(0xFFFE)
                pb = 0
            } else {
                let vector = memory.read24(0xFFE6)
                pb = UInt8((vector >> 16) & 0xFF)
                pc = UInt16(vector & 0xFFFF)
            }
            
        case 0xFB: // XCE - Exchange Carry with Emulation
            let oldCarry = getFlag(.carry)
            setFlag(.carry, isEmulationMode)
            isEmulationMode = oldCarry
            
            if isEmulationMode {
                // Entrando em modo emulação
                setFlag(.memory, true)   // Força modo 8-bit
                setFlag(.index, true)    // Força modo 8-bit
                x &= 0xFF               // Trunca X para 8 bits
                y &= 0xFF               // Trunca Y para 8 bits
                s = (s & 0xFF) | 0x0100 // Stack na página 1
            }
            // Stack Operations
        case 0x48: PHA()                    // PHA
        case 0x68: PLA()                    // PLA
        case 0xDA: PHX()                    // PHX
        case 0xFA: PLX()                    // PLX
        case 0x5A: PHY()                    // PHY
        case 0x7A: PLY()                    // PLY
        case 0x08: PHP()                    // PHP
        case 0x28: PLP()                    // PLP
        case 0x8B: // PHB
            pushByte(db)
        case 0xAB: // PLB
            db = popByte()
            updateNZ8(db)
        case 0x4B: // PHK
            pushByte(pb)
        case 0x0B: // PHD
            pushWord(d)
        case 0x2B: // PLD
            d = popWord()
            updateNZ16(d)
        case 0xD4: // PEI
            let addr = getDirectPageAddress()
            let value = memory.read16(addr)
            pushWord(value)
        case 0xF4: // PEA
            let value = fetchWord()
            pushWord(value)
        case 0x62: // PER
            let offset = fetchWord()
            let value = pc &+ offset
            pushWord(value)
            
            // Arithmetic Operations
        case 0x69: ADC_immediate()          // ADC #
        case 0x65: // ADC dp
            let addr = getDirectPageAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ADC_value(operand)
        case 0x75: // ADC dp,X
            let addr = getDirectPageXAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ADC_value(operand)
        case 0x6D: // ADC abs
            let addr = getAbsoluteAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ADC_value(operand)
        case 0x7D: // ADC abs,X
            let addr = getAbsoluteXAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ADC_value(operand)
        case 0x79: // ADC abs,Y
            let addr = getAbsoluteYAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ADC_value(operand)
        case 0x6F: // ADC long
            let addr = fetchLong()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ADC_value(operand)
        case 0x7F: // ADC long,X
            let addr = fetchLong() + UInt32(x)
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ADC_value(operand)
        case 0x67: // ADC [dp]
            let addr = getIndirectLongAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ADC_value(operand)
        case 0x77: // ADC [dp],Y
            let addr = getIndirectIndexedLongAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ADC_value(operand)
        case 0x61: // ADC (dp,X)
            let addr = getIndexedIndirectAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ADC_value(operand)
        case 0x71: // ADC (dp),Y
            let addr = getIndirectIndexedAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ADC_value(operand)
        case 0x63: // ADC sr,S
            let addr = getStackRelativeAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ADC_value(operand)
        case 0x73: // ADC (sr,S),Y
            let addr = getStackRelativeIndirectIndexedAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ADC_value(operand)
            
            // SBC - Subtract with Carry
        case 0xE9: SBC_immediate()          // SBC #
        case 0xE5: // SBC dp
            let addr = getDirectPageAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            SBC_value(operand)
        case 0xF5: // SBC dp,X
            let addr = getDirectPageXAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            SBC_value(operand)
        case 0xED: // SBC abs
            let addr = getAbsoluteAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            SBC_value(operand)
        case 0xFD: // SBC abs,X
            let addr = getAbsoluteXAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            SBC_value(operand)
        case 0xF9: // SBC abs,Y
            let addr = getAbsoluteYAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            SBC_value(operand)
        case 0xEF: // SBC long
            let addr = fetchLong()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            SBC_value(operand)
        case 0xFF: // SBC long,X
            let addr = fetchLong() + UInt32(x)
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            SBC_value(operand)
        case 0xE7: // SBC [dp]
            let addr = getIndirectLongAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            SBC_value(operand)
        case 0xF7: // SBC [dp],Y
            let addr = getIndirectIndexedLongAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            SBC_value(operand)
        case 0xE1: // SBC (dp,X)
            let addr = getIndexedIndirectAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            SBC_value(operand)
        case 0xF1: // SBC (dp),Y
            let addr = getIndirectIndexedAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            SBC_value(operand)
        case 0xE3: // SBC sr,S
            let addr = getStackRelativeAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            SBC_value(operand)
        case 0xF3: // SBC (sr,S),Y
            let addr = getStackRelativeIndirectIndexedAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            SBC_value(operand)
            
            // INC/DEC Operations
        case 0x1A: INC_accumulator()        // INC A
        case 0x3A: DEC_accumulator()        // DEC A
        case 0xE8: INX()                    // INX
        case 0xCA: DEX()                    // DEX
        case 0xC8: INY()                    // INY
        case 0x88: DEY()                    // DEY
        case 0xE6: // INC dp
            let addr = getDirectPageAddress()
            INC_memory(addr)
        case 0xF6: // INC dp,X
            let addr = getDirectPageXAddress()
            INC_memory(addr)
        case 0xEE: // INC abs
            let addr = getAbsoluteAddress()
            INC_memory(addr)
        case 0xFE: // INC abs,X
            let addr = getAbsoluteXAddress()
            INC_memory(addr)
        case 0xC6: // DEC dp
            let addr = getDirectPageAddress()
            DEC_memory(addr)
        case 0xD6: // DEC dp,X
            let addr = getDirectPageXAddress()
            DEC_memory(addr)
        case 0xCE: // DEC abs
            let addr = getAbsoluteAddress()
            DEC_memory(addr)
        case 0xDE: // DEC abs,X
            let addr = getAbsoluteXAddress()
            DEC_memory(addr)
            
            // Logical Operations
        case 0x29: AND_immediate()          // AND #
        case 0x25: // AND dp
            let addr = getDirectPageAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            AND_value(operand)
        case 0x35: // AND dp,X
            let addr = getDirectPageXAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            AND_value(operand)
        case 0x2D: // AND abs
            let addr = getAbsoluteAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            AND_value(operand)
        case 0x3D: // AND abs,X
            let addr = getAbsoluteXAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            AND_value(operand)
        case 0x39: // AND abs,Y
            let addr = getAbsoluteYAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            AND_value(operand)
        case 0x2F: // AND long
            let addr = fetchLong()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            AND_value(operand)
        case 0x3F: // AND long,X
            let addr = fetchLong() + UInt32(x)
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            AND_value(operand)
        case 0x27: // AND [dp]
            let addr = getIndirectLongAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            AND_value(operand)
        case 0x37: // AND [dp],Y
            let addr = getIndirectIndexedLongAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            AND_value(operand)
        case 0x21: // AND (dp,X)
            let addr = getIndexedIndirectAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            AND_value(operand)
        case 0x31: // AND (dp),Y
            let addr = getIndirectIndexedAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            AND_value(operand)
        case 0x23: // AND sr,S
            let addr = getStackRelativeAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            AND_value(operand)
        case 0x33: // AND (sr,S),Y
            let addr = getStackRelativeIndirectIndexedAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            AND_value(operand)
            
            // ORA Operations (similar pattern to AND)
        case 0x09: ORA_immediate()          // ORA #
        case 0x05: // ORA dp
            let addr = getDirectPageAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ORA_value(operand)
        case 0x15: // ORA dp,X
            let addr = getDirectPageXAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ORA_value(operand)
        case 0x0D: // ORA abs
            let addr = getAbsoluteAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ORA_value(operand)
        case 0x1D: // ORA abs,X
            let addr = getAbsoluteXAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ORA_value(operand)
        case 0x19: // ORA abs,Y
            let addr = getAbsoluteYAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ORA_value(operand)
        case 0x0F: // ORA long
            let addr = fetchLong()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ORA_value(operand)
        case 0x1F: // ORA long,X
            let addr = fetchLong() + UInt32(x)
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ORA_value(operand)
        case 0x07: // ORA [dp]
            let addr = getIndirectLongAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ORA_value(operand)
        case 0x17: // ORA [dp],Y
            let addr = getIndirectIndexedLongAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ORA_value(operand)
        case 0x01: // ORA (dp,X)
            let addr = getIndexedIndirectAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ORA_value(operand)
        case 0x11: // ORA (dp),Y
            let addr = getIndirectIndexedAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ORA_value(operand)
        case 0x03: // ORA sr,S
            let addr = getStackRelativeAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ORA_value(operand)
        case 0x13: // ORA (sr,S),Y
            let addr = getStackRelativeIndirectIndexedAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            ORA_value(operand)
            
            // EOR Operations (similar pattern)
        case 0x49: EOR_immediate()          // EOR #
        case 0x45: // EOR dp
            let addr = getDirectPageAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            EOR_value(operand)
        case 0x55: // EOR dp,X
            let addr = getDirectPageXAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            EOR_value(operand)
        case 0x4D: // EOR abs
            let addr = getAbsoluteAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            EOR_value(operand)
        case 0x5D: // EOR abs,X
            let addr = getAbsoluteXAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            EOR_value(operand)
        case 0x59: // EOR abs,Y
            let addr = getAbsoluteYAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            EOR_value(operand)
        case 0x4F: // EOR long
            let addr = fetchLong()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            EOR_value(operand)
        case 0x5F: // EOR long,X
            let addr = fetchLong() + UInt32(x)
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            EOR_value(operand)
        case 0x47: // EOR [dp]
            let addr = getIndirectLongAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            EOR_value(operand)
        case 0x57: // EOR [dp],Y
            let addr = getIndirectIndexedLongAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            EOR_value(operand)
        case 0x41: // EOR (dp,X)
            let addr = getIndexedIndirectAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            EOR_value(operand)
        case 0x51: // EOR (dp),Y
            let addr = getIndirectIndexedAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            EOR_value(operand)
        case 0x43: // EOR sr,S
            let addr = getStackRelativeAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            EOR_value(operand)
        case 0x53: // EOR (sr,S),Y
            let addr = getStackRelativeIndirectIndexedAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            EOR_value(operand)
            
            // Compare Operations
        case 0xC9: CMP_immediate()          // CMP #
        case 0xC5: // CMP dp
            let addr = getDirectPageAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CMP_value(operand)
        case 0xD5: // CMP dp,X
            let addr = getDirectPageXAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CMP_value(operand)
        case 0xCD: // CMP abs
            let addr = getAbsoluteAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CMP_value(operand)
        case 0xDD: // CMP abs,X
            let addr = getAbsoluteXAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CMP_value(operand)
        case 0xD9: // CMP abs,Y
            let addr = getAbsoluteYAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CMP_value(operand)
        case 0xCF: // CMP long
            let addr = fetchLong()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CMP_value(operand)
        case 0xDF: // CMP long,X
            let addr = fetchLong() + UInt32(x)
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CMP_value(operand)
        case 0xC7: // CMP [dp]
            let addr = getIndirectLongAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CMP_value(operand)
        case 0xD7: // CMP [dp],Y
            let addr = getIndirectIndexedLongAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CMP_value(operand)
        case 0xC1: // CMP (dp,X)
            let addr = getIndexedIndirectAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CMP_value(operand)
        case 0xD1: // CMP (dp),Y
            let addr = getIndirectIndexedAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CMP_value(operand)
        case 0xC3: // CMP sr,S
            let addr = getStackRelativeAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CMP_value(operand)
        case 0xD3: // CMP (sr,S),Y
            let addr = getStackRelativeIndirectIndexedAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CMP_value(operand)
            
            // CPX Operations
        case 0xE0: CPX_immediate()          // CPX #
        case 0xE4: // CPX dp
            let addr = getDirectPageAddress()
            let operand = getFlag(.index) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CPX_value(operand)
        case 0xEC: // CPX abs
            let addr = getAbsoluteAddress()
            let operand = getFlag(.index) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CPX_value(operand)
            
            // CPY Operations
        case 0xC0: CPY_immediate()          // CPY #
        case 0xC4: // CPY dp
            let addr = getDirectPageAddress()
            let operand = getFlag(.index) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CPY_value(operand)
        case 0xCC: // CPY abs
            let addr = getAbsoluteAddress()
            let operand = getFlag(.index) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            CPY_value(operand)
            
            // Bit Operations
        case 0x89: // BIT #
            let operand = getFlag(.memory) ? UInt16(fetchByte()) : fetchWord()
            BIT_value(operand)
        case 0x24: // BIT dp
            let addr = getDirectPageAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            BIT_value(operand)
        case 0x34: // BIT dp,X
            let addr = getDirectPageXAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            BIT_value(operand)
        case 0x2C: // BIT abs
            let addr = getAbsoluteAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            BIT_value(operand)
        case 0x3C: // BIT abs,X
            let addr = getAbsoluteXAddress()
            let operand = getFlag(.memory) ? UInt16(memory.read8(addr)) : memory.read16(addr)
            BIT_value(operand)
            
            // Shift/Rotate Operations
        case 0x0A: ASL_accumulator()        // ASL A
        case 0x06: // ASL dp
            let addr = getDirectPageAddress()
            ASL_memory(addr)
        case 0x16: // ASL dp,X
            let addr = getDirectPageXAddress()
            ASL_memory(addr)
        case 0x0E: // ASL abs
            let addr = getAbsoluteAddress()
            ASL_memory(addr)
        case 0x1E: // ASL abs,X
            let addr = getAbsoluteXAddress()
            ASL_memory(addr)
            
        case 0x4A: LSR_accumulator()        // LSR A
        case 0x46: // LSR dp
            let addr = getDirectPageAddress()
            LSR_memory(addr)
        case 0x56: // LSR dp,X
            let addr = getDirectPageXAddress()
            LSR_memory(addr)
        case 0x4E: // LSR abs
            let addr = getAbsoluteAddress()
            LSR_memory(addr)
        case 0x5E: // LSR abs,X
            let addr = getAbsoluteXAddress()
            LSR_memory(addr)
            
        case 0x2A: ROL_accumulator()        // ROL A
        case 0x26: // ROL dp
            let addr = getDirectPageAddress()
            ROL_memory(addr)
        case 0x36: // ROL dp,X
            let addr = getDirectPageXAddress()
            ROL_memory(addr)
        case 0x2E: // ROL abs
            let addr = getAbsoluteAddress()
            ROL_memory(addr)
        case 0x3E: // ROL abs,X
            let addr = getAbsoluteXAddress()
            ROL_memory(addr)
            
        case 0x6A: ROR_accumulator()        // ROR A
        case 0x66: // ROR dp
            let addr = getDirectPageAddress()
            ROR_memory(addr)
        case 0x76: // ROR dp,X
            let addr = getDirectPageXAddress()
            ROR_memory(addr)
        case 0x6E: // ROR abs
            let addr = getAbsoluteAddress()
            ROR_memory(addr)
        case 0x7E: // ROR abs,X
            let addr = getAbsoluteXAddress()
            ROR_memory(addr)
            
            // Branch Operations
        case 0x90: BCC()                    // BCC
        case 0xB0: BCS()                    // BCS
        case 0xF0: BEQ()                    // BEQ
        case 0xD0: BNE()                    // BNE
        case 0x30: BMI()                    // BMI
        case 0x10: BPL()                    // BPL
        case 0x50: BVC()                    // BVC
        case 0x70: BVS()                    // BVS
        case 0x80: // BRA (Branch Always)
            branch(true)
        case 0x82: // BRL (Branch Long)
            let offset = Int16(bitPattern: fetchWord())
            pc = UInt16(Int16(pc) + offset)
            
            // Jump Operations
        case 0x4C: JMP_absolute()           // JMP abs
        case 0x5C: JMP_absoluteLong()       // JMP long
        case 0x6C: // JMP (abs)
            let pointer = getAbsoluteAddress()
            pc = memory.read16(pointer)
        case 0x7C: // JMP (abs,X)
            let base = fetchWord()
            let pointer = UInt32(pb) << 16 | UInt32(base &+ x)
            pc = memory.read16(pointer)
        case 0xDC: // JMP [abs]
            let pointer = getAbsoluteAddress()
            let addr = memory.read24(pointer)
            pb = UInt8((addr >> 16) & 0xFF)
            pc = UInt16(addr & 0xFFFF)
            
        case 0x20: JSR_absolute()           // JSR abs
        case 0x22: JSL_absoluteLong()       // JSL long
        case 0xFC: // JSR (abs,X)
            let base = fetchWord()
            let addr = base &+ x
            pushWord(pc - 1)
            pc = addr
            
        case 0x60: RTS()                    // RTS
        case 0x6B: RTL()                    // RTL
        case 0x40: // RTI
            p = popByte()
            if isEmulationMode {
                p |= 0x30  // Force M and X flags
            }
            pc = popWord()
            if !isEmulationMode {
                pb = popByte()
            }
            
            // Flag Operations
        case 0x18: CLC()                    // CLC
        case 0x38: SEC()                    // SEC
        case 0x58: CLI()                    // CLI
        case 0x78: SEI()                    // SEI
        case 0xD8: CLD()                    // CLD
        case 0xF8: SED()                    // SED
        case 0xB8: CLV()                    // CLV
        case 0xC2: REP()                    // REP
        case 0xE2: SEP()                    // SEP
            
            // Misc Operations
        case 0x44: // MVP (Block Move)
            let dest = fetchByte()
            let src = fetchByte()
            
            // Move byte from src to dest
            let srcAddr = UInt32(src) << 16 | UInt32(x)
            let destAddr = UInt32(dest) << 16 | UInt32(y)
            let value = memory.read8(srcAddr)
            memory.write8(destAddr, value)
            
            // Update registers
            if a != 0xFFFF {
                a = a &- 1
                x = x &- 1
                y = y &- 1
                pc = pc &- 3  // Repeat instruction
            }
            db = dest
            
        case 0x54: // MVN (Block Move)
            let dest = fetchByte()
            let src = fetchByte()
            
            // Move byte from src to dest
            let srcAddr = UInt32(src) << 16 | UInt32(x)
            let destAddr = UInt32(dest) << 16 | UInt32(y)
            let value = memory.read8(srcAddr)
            memory.write8(destAddr, value)
            
            // Update registers
            if a != 0xFFFF {
                a = a &- 1
                x = x &+ 1
                y = y &+ 1
                pc = pc &- 3  // Repeat instruction
            }
            db = dest
            
            // Test and Set/Reset Bits
        case 0x04: // TSB dp
            let addr = getDirectPageAddress()
            TSB_memory(addr)
        case 0x0C: // TSB abs
            let addr = getAbsoluteAddress()
            TSB_memory(addr)
        case 0x14: // TRB dp
            let addr = getDirectPageAddress()
            TRB_memory(addr)
        case 0x1C: // TRB abs
            let addr = getAbsoluteAddress()
            TRB_memory(addr)
            
        default:
            print("Opcode não implementado: \(String(format: "$%02X", opcode)) at PC: \(String(format: "$%02X:%04X", pb, pc - 1))")
                
            // Mostra contexto ao redor
            print("  Contexto:")
            for i in -5...5 {
                let offset = Int32(pc) - 1 + Int32(i)
                if offset >= 0 && offset <= 0xFFFF {
                    let addr = UInt32(pb) << 16 | UInt32(offset)
                    let byte = memory.read8(addr)
                    if i == 0 {
                        print("  > [\(String(format: "$%06X", addr))] = \(String(format: "$%02X", byte)) <-- PC")
                    } else {
                        print("    [\(String(format: "$%06X", addr))] = \(String(format: "$%02X", byte))")
                    }
                }
            }
            
            // Estado dos registradores
            print("  Registradores:")
            print("    A: \(String(format: "$%04X", a))  X: \(String(format: "$%04X", x))  Y: \(String(format: "$%04X", y))")
            print("    S: \(String(format: "$%04X", s))  D: \(String(format: "$%04X", d))  P: \(String(format: "$%02X", p))")
            print("    DB: \(String(format: "$%02X", db))  PB: \(String(format: "$%02X", pb))")
            
            // Força um NOP para continuar
            cycles += 2
        }
    }
    
    // MARK: - Helper Functions
    
    private func fetchLong() -> UInt32 {
        print("fetchLong() chamado em PC: \(String(format: "$%02X:%04X", pb, pc))")
        let low = UInt32(fetchByte())
        print("  low byte: \(String(format: "$%02X", low)), PC agora: \(String(format: "$%04X", pc))")
        let mid = UInt32(fetchByte())
        print("  mid byte: \(String(format: "$%02X", mid)), PC agora: \(String(format: "$%04X", pc))")
        let high = UInt32(fetchByte())
        print("  high byte: \(String(format: "$%02X", high)), PC agora: \(String(format: "$%04X", pc))")
        let result = (high << 16) | (mid << 8) | low
        print("  resultado: \(String(format: "$%06X", result))")
        return result
    }

    private func getAbsoluteYAddress() -> UInt32 {
        let base = fetchWord()
        let addr = base &+ y
        return UInt32(db) << 16 | UInt32(addr)
    }

    private func getIndirectLongAddress() -> UInt32 {
        let pointer = getDirectPageAddress()
        return memory.read24(pointer)
    }

    private func getIndirectIndexedLongAddress() -> UInt32 {
        let base = fetchByte()
        let pointer = UInt32(d &+ UInt16(base))
        let addr = memory.read24(pointer)
        return addr + UInt32(y)
    }

    private func getIndexedIndirectAddress() -> UInt32 {
        let base = fetchByte()
        let pointer = UInt32(d &+ UInt16(base) &+ x)
        let addr = memory.read16(pointer)
        return UInt32(db) << 16 | UInt32(addr)
    }

    private func getIndirectIndexedAddress() -> UInt32 {
        let base = fetchByte()
        let pointer = UInt32(d &+ UInt16(base))
        let addr = memory.read16(pointer)
        let finalAddr = addr &+ y
        return UInt32(db) << 16 | UInt32(finalAddr)
    }

    private func getStackRelativeAddress() -> UInt32 {
        let offset = fetchByte()
        return UInt32(s &+ UInt16(offset))
    }

    private func getStackRelativeIndirectIndexedAddress() -> UInt32 {
        let offset = fetchByte()
        let pointer = UInt32(s &+ UInt16(offset))
        let addr = memory.read16(pointer)
        return UInt32(db) << 16 | UInt32(addr &+ y)
    }

    private func CPX_immediate() {
        if getFlag(.index) {
            let operand = fetchByte()
            CPX_value(UInt16(operand))
        } else {
            let operand = fetchWord()
            CPX_value(operand)
        }
    }

    private func CPY_immediate() {
        if getFlag(.index) {
            let operand = fetchByte()
            CPY_value(UInt16(operand))
        } else {
            let operand = fetchWord()
            CPY_value(operand)
        }
    }

    private func ASL_accumulator() {
        if getFlag(.memory) {
            let value = a & 0xFF
            setFlag(.carry, (value & 0x80) != 0)
            a = (a & 0xFF00) | ((value << 1) & 0xFF)
            updateNZ8(UInt8(a & 0xFF))
        } else {
            setFlag(.carry, (a & 0x8000) != 0)
            a = a << 1
            updateNZ16(a)
        }
    }

    private func LSR_accumulator() {
        if getFlag(.memory) {
            let value = a & 0xFF
            setFlag(.carry, (value & 0x01) != 0)
            a = (a & 0xFF00) | (value >> 1)
            updateNZ8(UInt8(a & 0xFF))
        } else {
            setFlag(.carry, (a & 0x01) != 0)
            a = a >> 1
            updateNZ16(a)
        }
    }

    private func JMP_absolute() {
        pc = fetchWord()
    }

    private func JMP_absoluteLong() {
        let addr = fetchLong()
        pb = UInt8((addr >> 16) & 0xFF)
        pc = UInt16(addr & 0xFFFF)
    }

    private func JSR_absolute() {
        let addr = fetchWord()
        pushWord(pc - 1)
        pc = addr
    }

    private func JSL_absoluteLong() {
        let addr = fetchLong()
        pushByte(pb)
        pushWord(pc - 1)
        pb = UInt8((addr >> 16) & 0xFF)
        pc = UInt16(addr & 0xFFFF)
    }
    
    private func RTS() {
        pc = popWord() + 1
    }

    private func RTL() {
        pc = popWord() + 1
        pb = popByte()
    }

    private func popByte() -> UInt8 {
        s = s &+ 1
        if isEmulationMode {
            s = (s & 0xFF) | 0x0100
        }
        return memory.read8(UInt32(s))
    }

    private func popWord() -> UInt16 {
        let low = UInt16(popByte())
        let high = UInt16(popByte())
        return (high << 8) | low
    }
    
    private func ADC_value(_ operand: UInt16) {
        if getFlag(.memory) {
            let result = (a & 0xFF) + (operand & 0xFF) + (getFlag(.carry) ? 1 : 0)
            
            setFlag(.carry, result > 0xFF)
            setFlag(.overflow, ((a ^ result) & (operand ^ result) & 0x80) != 0)
            
            a = (a & 0xFF00) | (result & 0xFF)
            updateNZ8(UInt8(a & 0xFF))
        } else {
            let result = UInt32(a) + UInt32(operand) + (getFlag(.carry) ? 1 : 0)
            
            setFlag(.carry, result > 0xFFFF)
            setFlag(.overflow, ((a ^ UInt16(result)) & (operand ^ UInt16(result)) & 0x8000) != 0)
            
            a = UInt16(result & 0xFFFF)
            updateNZ16(a)
        }
    }
    
    private func SBC_value(_ operand: UInt16) {
        if getFlag(.memory) {
            let result = Int16(a & 0xFF) - Int16(operand & 0xFF) - (getFlag(.carry) ? 0 : 1)
            
            setFlag(.carry, result >= 0)
            setFlag(.overflow, ((a ^ UInt16(bitPattern: result)) & ((a ^ operand) & 0x80)) != 0)
            
            a = (a & 0xFF00) | UInt16(UInt8(result & 0xFF))
            updateNZ8(UInt8(a & 0xFF))
        } else {
            let result = Int32(a) - Int32(operand) - (getFlag(.carry) ? 0 : 1)
            
            setFlag(.carry, result >= 0)
            setFlag(.overflow, ((a ^ UInt16(result)) & (a ^ operand) & 0x8000) != 0)
            
            a = UInt16(result & 0xFFFF)
            updateNZ16(a)
        }
    }
    
    private func AND_value(_ operand: UInt16) {
        if getFlag(.memory) {
            a = (a & 0xFF00) | ((a & 0xFF) & (operand & 0xFF))
            updateNZ8(UInt8(a & 0xFF))
        } else {
            a = a & operand
            updateNZ16(a)
        }
    }
    
    private func ORA_value(_ operand: UInt16) {
        if getFlag(.memory) {
            a = (a & 0xFF00) | ((a & 0xFF) | (operand & 0xFF))
            updateNZ8(UInt8(a & 0xFF))
        } else {
            a = a | operand
            updateNZ16(a)
        }
    }
    
    private func EOR_value(_ operand: UInt16) {
        if getFlag(.memory) {
            a = (a & 0xFF00) | ((a & 0xFF) ^ (operand & 0xFF))
            updateNZ8(UInt8(a & 0xFF))
        } else {
            a = a ^ operand
            updateNZ16(a)
        }
    }
    
    private func CMP_value(_ operand: UInt16) {
        if getFlag(.memory) {
            let result = Int16(a & 0xFF) - Int16(operand & 0xFF)
            setFlag(.carry, result >= 0)
            updateNZ8(UInt8(result & 0xFF))
        } else {
            let result = Int32(a) - Int32(operand)
            setFlag(.carry, result >= 0)
            updateNZ16(UInt16(result & 0xFFFF))
        }
    }
    
    private func CPX_value(_ operand: UInt16) {
        if getFlag(.index) {
            let result = Int16(x & 0xFF) - Int16(operand & 0xFF)
            setFlag(.carry, result >= 0)
            updateNZ8(UInt8(result & 0xFF))
        } else {
            let result = Int32(x) - Int32(operand)
            setFlag(.carry, result >= 0)
            updateNZ16(UInt16(result & 0xFFFF))
        }
    }
    
    private func CPY_value(_ operand: UInt16) {
        if getFlag(.index) {
            let result = Int16(y & 0xFF) - Int16(operand & 0xFF)
            setFlag(.carry, result >= 0)
            updateNZ8(UInt8(result & 0xFF))
        } else {
            let result = Int32(y) - Int32(operand)
            setFlag(.carry, result >= 0)
            updateNZ16(UInt16(result & 0xFFFF))
        }
    }
    
    private func BIT_value(_ operand: UInt16) {
        if getFlag(.memory) {
            let result = (a & 0xFF) & (operand & 0xFF)
            setFlag(.zero, result == 0)
            setFlag(.overflow, (operand & 0x40) != 0)
            setFlag(.negative, (operand & 0x80) != 0)
        } else {
            let result = a & operand
            setFlag(.zero, result == 0)
            setFlag(.overflow, (operand & 0x4000) != 0)
            setFlag(.negative, (operand & 0x8000) != 0)
        }
    }
    
    private func INC_memory(_ addr: UInt32) {
        if getFlag(.memory) {
            let value = (memory.read8(addr) &+ 1) & 0xFF
            memory.write8(addr, value)
            updateNZ8(value)
        } else {
            let value = memory.read16(addr) &+ 1
            memory.write16(addr, value)
            updateNZ16(value)
        }
    }
    
    private func DEC_memory(_ addr: UInt32) {
        if getFlag(.memory) {
            let value = (memory.read8(addr) &- 1) & 0xFF
            memory.write8(addr, value)
            updateNZ8(value)
        } else {
            let value = memory.read16(addr) &- 1
            memory.write16(addr, value)
            updateNZ16(value)
        }
    }
    
    private func ASL_memory(_ addr: UInt32) {
        if getFlag(.memory) {
            let value = memory.read8(addr)
            setFlag(.carry, (value & 0x80) != 0)
            let result = (value << 1) & 0xFF
            memory.write8(addr, result)
            updateNZ8(result)
        } else {
            let value = memory.read16(addr)
            setFlag(.carry, (value & 0x8000) != 0)
            let result = value << 1
            memory.write16(addr, result)
            updateNZ16(result)
        }
    }
    
    private func LSR_memory(_ addr: UInt32) {
        if getFlag(.memory) {
            let value = memory.read8(addr)
            setFlag(.carry, (value & 0x01) != 0)
            let result = value >> 1
            memory.write8(addr, result)
            updateNZ8(result)
        } else {
            let value = memory.read16(addr)
            setFlag(.carry, (value & 0x01) != 0)
            let result = value >> 1
            memory.write16(addr, result)
            updateNZ16(result)
        }
    }
    
    private func ROL_memory(_ addr: UInt32) {
        if getFlag(.memory) {
            let value = memory.read8(addr)
            let carry = getFlag(.carry) ? 1 : 0
            setFlag(.carry, (value & 0x80) != 0)
            let result = ((value << 1) | UInt8(carry)) & 0xFF
            memory.write8(addr, result)
            updateNZ8(result)
        } else {
            let value = memory.read16(addr)
            let carry = getFlag(.carry) ? 1 : 0
            setFlag(.carry, (value & 0x8000) != 0)
            let result = (value << 1) | UInt16(carry)
            memory.write16(addr, result)
            updateNZ16(result)
        }
    }
    
    private func ROR_memory(_ addr: UInt32) {
        if getFlag(.memory) {
            let value = memory.read8(addr)
            let carry = getFlag(.carry) ? 0x80 : 0
            setFlag(.carry, (value & 0x01) != 0)
            let result = (value >> 1) | UInt8(carry)
            memory.write8(addr, result)
            updateNZ8(result)
        } else {
            let value = memory.read16(addr)
            let carry = getFlag(.carry) ? 0x8000 : 0
            setFlag(.carry, (value & 0x01) != 0)
            let result = (value >> 1) | UInt16(carry)
            memory.write16(addr, result)
            updateNZ16(result)
        }
    }
    
    private func TSB_memory(_ addr: UInt32) {
        if getFlag(.memory) {
            let value = memory.read8(addr)
            let result = UInt8(a & 0xFF) & value
            setFlag(.zero, result == 0)
            memory.write8(addr, value | UInt8(a & 0xFF))
        } else {
            let value = memory.read16(addr)
            let result = a & value
            setFlag(.zero, result == 0)
            memory.write16(addr, value | a)
        }
    }

    private func TRB_memory(_ addr: UInt32) {
        if getFlag(.memory) {
            let value = memory.read8(addr)
            let result = UInt8(a & 0xFF) & value
            setFlag(.zero, result == 0)
            memory.write8(addr, value & ~UInt8(a & 0xFF))
        } else {
            let value = memory.read16(addr)
            let result = a & value
            setFlag(.zero, result == 0)
            memory.write16(addr, value & ~a)
        }
    }
    
    // Cycle counting for instructions
    private func getBaseCycles(_ opcode: UInt8) -> Int {
        // This is a simplified version - real cycle counts vary based on
        // addressing mode, page crosses, and other factors
        switch opcode {
        case 0x00: return 7  // BRK
        case 0x01, 0x03: return 6  // ORA indirect
        case 0x02: return 7  // COP
        case 0x04, 0x05: return 3  // TSB/ORA dp
        case 0x06: return 5  // ASL dp
        case 0x07: return 6  // ORA [dp]
        case 0x08: return 3  // PHP
        case 0x09: return 2  // ORA immediate
        case 0x0A: return 2  // ASL A
        case 0x0B: return 4  // PHD
        case 0x0C: return 6  // TSB abs
        case 0x0D: return 4  // ORA abs
        case 0x0E: return 6  // ASL abs
        case 0x0F: return 5  // ORA long
        case 0x10: return 2  // BPL
            
            // Continue for all opcodes...
        default: return 2
        }
    }
    
    // MARK: - State Management
    
    struct State: Codable {
        let a: UInt16
        let x: UInt16
        let y: UInt16
        let s: UInt16
        let d: UInt16
        let db: UInt8
        let pb: UInt8
        let pc: UInt16
        let p: UInt8
        let isEmulationMode: Bool
        let cycles: Int
    }
    
    func getState() -> State {
        return State(
            a: a, x: x, y: y, s: s, d: d,
            db: db, pb: pb, pc: pc, p: p,
            isEmulationMode: isEmulationMode,
            cycles: cycles
        )
    }
    
    func setState(_ state: State) {
        a = state.a
        x = state.x
        y = state.y
        s = state.s
        d = state.d
        db = state.db
        pb = state.pb
        pc = state.pc
        p = state.p
        isEmulationMode = state.isEmulationMode
        cycles = state.cycles
    }
    
    // Flag Operations
    private func CLC() {
        setFlag(.carry, false)
    }
    
    private func SEC() {
        setFlag(.carry, true)
    }
    
    private func CLI() {
        setFlag(.irqDisable, false)
    }
    
    private func SEI() {
        setFlag(.irqDisable, true)
    }
    
    private func CLD() {
        setFlag(.decimal, false)
    }
    
    private func SED() {
        setFlag(.decimal, true)
    }
    
    private func CLV() {
        setFlag(.overflow, false)
    }
    
    private func REP() {
        let mask = fetchByte()
        p &= ~mask
        if isEmulationMode {
            p |= 0x30  // Force M and X flags in emulation mode
        }
    }
    
    private func SEP() {
        let mask = fetchByte()
        p |= mask
    }
    
    private func updateNZ8(_ value: UInt8) {
        setFlag(.zero, value == 0)
        setFlag(.negative, (value & 0x80) != 0)
    }

    private func updateNZ16(_ value: UInt16) {
        setFlag(.zero, value == 0)
        setFlag(.negative, (value & 0x8000) != 0)
    }
    
    private func getAbsoluteAddress() -> UInt32 {
        let addr = fetchWord()
        return UInt32(db) << 16 | UInt32(addr)
    }

    private func getDirectPageAddress() -> UInt32 {
        let offset = fetchByte()
        return UInt32(d &+ UInt16(offset))
    }
    
    // Branch Instructions
    private func branch(_ condition: Bool) {
        let offset = Int8(bitPattern: fetchByte())
        if condition {
            let oldPC = pc
            pc = UInt16(Int16(pc) + Int16(offset))
            
            // Add cycles for branch taken and page cross
            cycles += 1
            if (oldPC & 0xFF00) != (pc & 0xFF00) {
                cycles += 1
            }
        }
    }

    private func BCC() {
        branch(!getFlag(.carry))
    }

    private func BCS() {
        branch(getFlag(.carry))
    }

    private func BEQ() {
        branch(getFlag(.zero))
    }

    private func BNE() {
        branch(!getFlag(.zero))
    }

    private func BMI() {
        branch(getFlag(.negative))
    }

    private func BPL() {
        branch(!getFlag(.negative))
    }

    private func BVC() {
        branch(!getFlag(.overflow))
    }

    private func BVS() {
        branch(getFlag(.overflow))
    }
    
    private var pageCrossed: Bool = false
    
    private func getAbsoluteXAddress() -> UInt32 {
        let base = fetchWord()
        let addr = base &+ x
        pageCrossed = (base & 0xFF00) != (addr & 0xFF00)
        return UInt32(db) << 16 | UInt32(addr)
    }

    private func getDirectPageXAddress() -> UInt32 {
        let offset = fetchByte()
        return UInt32(d &+ UInt16(offset) &+ x)
    }

    private func ROL_accumulator() {
        if getFlag(.memory) {
            let value = a & 0xFF
            let carry = getFlag(.carry) ? UInt16(1) : UInt16(0)
            setFlag(.carry, (value & 0x80) != 0)
            a = (a & 0xFF00) | ((value << 1) | carry) & 0xFF
            updateNZ8(UInt8(a & 0xFF))
        } else {
            let carry = getFlag(.carry) ? UInt16(1) : UInt16(0)
            setFlag(.carry, (a & 0x8000) != 0)
            a = (a << 1) | carry
            updateNZ16(a)
        }
    }

    private func ROR_accumulator() {
        if getFlag(.memory) {
            let value = a & 0xFF
            let carry = getFlag(.carry) ? UInt16(0x80) : UInt16(0)
            setFlag(.carry, (value & 0x01) != 0)
            a = (a & 0xFF00) | ((value >> 1) | carry)
            updateNZ8(UInt8(a & 0xFF))
        } else {
            let carry = getFlag(.carry) ? UInt16(0x8000) : UInt16(0)
            setFlag(.carry, (a & 0x01) != 0)
            a = (a >> 1) | carry
            updateNZ16(a)
        }
    }
    
    private func pushWord(_ value: UInt16) {
        pushByte(UInt8((value >> 8) & 0xFF))
        pushByte(UInt8(value & 0xFF))
    }

    private func CMP_immediate() {
        if getFlag(.memory) {
            let operand = fetchByte()
            CMP_value(UInt16(operand))
        } else {
            let operand = fetchWord()
            CMP_value(operand)
        }
    }

    private func EOR_immediate() {
        if getFlag(.memory) {
            let operand = UInt16(fetchByte())
            EOR_value(operand)
        } else {
            let operand = fetchWord()
            EOR_value(operand)
        }
    }

    private func ORA_immediate() {
        if getFlag(.memory) {
            let operand = UInt16(fetchByte())
            ORA_value(operand)
        } else {
            let operand = fetchWord()
            ORA_value(operand)
        }
    }

    private func AND_immediate() {
        if getFlag(.memory) {
            let operand = UInt16(fetchByte())
            AND_value(operand)
        } else {
            let operand = fetchWord()
            AND_value(operand)
        }
    }

    private func INC_accumulator() {
        if getFlag(.memory) {
            a = (a & 0xFF00) | ((a + 1) & 0xFF)
            updateNZ8(UInt8(a & 0xFF))
        } else {
            a = a &+ 1
            updateNZ16(a)
        }
    }

    private func DEC_accumulator() {
        if getFlag(.memory) {
            a = (a & 0xFF00) | ((a - 1) & 0xFF)
            updateNZ8(UInt8(a & 0xFF))
        } else {
            a = a &- 1
            updateNZ16(a)
        }
    }

    private func INX() {
        if getFlag(.index) {
            x = (x + 1) & 0xFF
            updateNZ8(UInt8(x))
        } else {
            x = x &+ 1
            updateNZ16(x)
        }
    }

    private func DEX() {
        if getFlag(.index) {
            x = (x - 1) & 0xFF
            updateNZ8(UInt8(x))
        } else {
            x = x &- 1
            updateNZ16(x)
        }
    }

    private func INY() {
        if getFlag(.index) {
            y = (y + 1) & 0xFF
            updateNZ8(UInt8(y))
        } else {
            y = y &+ 1
            updateNZ16(y)
        }
    }

    private func DEY() {
        if getFlag(.index) {
            y = (y - 1) & 0xFF
            updateNZ8(UInt8(y))
        } else {
            y = y &- 1
            updateNZ16(y)
        }
    }

    private func SBC_immediate() {
        if getFlag(.memory) {
            let operand = UInt16(fetchByte())
            SBC_value(operand)
        } else {
            let operand = fetchWord()
            SBC_value(operand)
        }
    }

    private func ADC_immediate() {
        if getFlag(.memory) {
            let operand = UInt16(fetchByte())
            ADC_value(operand)
        } else {
            let operand = fetchWord()
            ADC_value(operand)
        }
    }

    private func PHA() {
        if getFlag(.memory) {
            pushByte(UInt8(a & 0xFF))
        } else {
            pushWord(a)
        }
    }

    private func PLA() {
        if getFlag(.memory) {
            a = (a & 0xFF00) | UInt16(popByte())
            updateNZ8(UInt8(a & 0xFF))
        } else {
            a = popWord()
            updateNZ16(a)
        }
    }

    private func PHX() {
        if getFlag(.index) {
            pushByte(UInt8(x & 0xFF))
        } else {
            pushWord(x)
        }
    }

    private func PLX() {
        if getFlag(.index) {
            x = UInt16(popByte())
            updateNZ8(UInt8(x))
        } else {
            x = popWord()
            updateNZ16(x)
        }
    }

    private func PHY() {
        if getFlag(.index) {
            pushByte(UInt8(y & 0xFF))
        } else {
            pushWord(y)
        }
    }

    private func PLY() {
        if getFlag(.index) {
            y = UInt16(popByte())
            updateNZ8(UInt8(y))
        } else {
            y = popWord()
            updateNZ16(y)
        }
    }

    private func PHP() {
        pushByte(p | 0x30)  // Set B flag
    }

    private func PLP() {
        p = popByte()
        if isEmulationMode {
            p |= 0x30  // Force M and X flags in emulation mode
        }
    }
    
    private func TAX() {
        if getFlag(.index) {
            x = a & 0xFF
            updateNZ8(UInt8(x))
        } else {
            x = a
            updateNZ16(x)
        }
    }

    private func TAY() {
        if getFlag(.index) {
            y = a & 0xFF
            updateNZ8(UInt8(y))
        } else {
            y = a
            updateNZ16(y)
        }
    }

    private func TXA() {
        if getFlag(.memory) {
            a = (a & 0xFF00) | (x & 0xFF)
            updateNZ8(UInt8(a & 0xFF))
        } else {
            a = x
            updateNZ16(a)
        }
    }

    private func TYA() {
        if getFlag(.memory) {
            a = (a & 0xFF00) | (y & 0xFF)
            updateNZ8(UInt8(a & 0xFF))
        } else {
            a = y
            updateNZ16(a)
        }
    }

    private func TSX() {
        if getFlag(.index) {
            x = s & 0xFF
            updateNZ8(UInt8(x))
        } else {
            x = s
            updateNZ16(x)
        }
    }

    private func TXS() {
        if isEmulationMode {
            s = 0x0100 | (x & 0xFF)
        } else {
            s = x
        }
    }

    private func STZ_absolute() {
        let addr = getAbsoluteAddress()
        if getFlag(.memory) {
            memory.write8(addr, 0)
        } else {
            memory.write16(addr, 0)
        }
    }

    private func STY_absolute() {
        let addr = getAbsoluteAddress()
        if getFlag(.index) {
            memory.write8(addr, UInt8(y & 0xFF))
        } else {
            memory.write16(addr, y)
        }
    }

    private func LDY_immediate() {
        if getFlag(.index) {
            y = UInt16(fetchByte())
            updateNZ8(UInt8(y))
        } else {
            y = fetchWord()
            updateNZ16(y)
        }
    }

    private func pushByte(_ value: UInt8) {
        memory.write8(UInt32(s), value)
        s = s &- 1
        if isEmulationMode {
            s = (s & 0xFF) | 0x0100
        }
    }

    private func getDirectPageYAddress() -> UInt32 {
        let offset = fetchByte()
        return UInt32(d &+ UInt16(offset) &+ y)
    }

    private func LDX_immediate() {
        if getFlag(.index) {
            x = UInt16(fetchByte())
            updateNZ8(UInt8(x))
        } else {
            x = fetchWord()
            updateNZ16(x)
        }
    }

    private func STA_absolute() {
        let addr = getAbsoluteAddress()
        if getFlag(.memory) {
            memory.write8(addr, UInt8(a & 0xFF))
        } else {
            memory.write16(addr, a)
        }
    }
    
    private func STX_absolute() {
        let addr = getAbsoluteAddress()
        if getFlag(.index) {
            memory.write8(addr, UInt8(x & 0xFF))
        } else {
            memory.write16(addr, x)
        }
    }
}



// Extension for MemoryBus to support 24-bit reads
extension MemoryBus {
    func read24(_ address: UInt32) -> UInt32 {
        let low = UInt32(read8(address))
        let mid = UInt32(read8(address + 1))
        let high = UInt32(read8(address + 2))
        return (high << 16) | (mid << 8) | low
    }
}
