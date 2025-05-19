// MemoryBus.swift
import Foundation

class MemoryBus {
    // Mapa de memória do SNES
    private var wram: [UInt8] = Array(repeating: 0, count: 0x20000)  // 128KB Work RAM
    private var sram: [UInt8] = Array(repeating: 0, count: 0x8000)   // 32KB Save RAM
    private var rom: Data = Data()
    
    // Referências para componentes (weak para evitar retain cycles)
    private weak var cpu: CPU65816?
    private weak var ppu: PPU?
    private weak var apu: APU?
    
    // Registradores mapeados na memória
    private var ioRegisters: [UInt8] = Array(repeating: 0, count: 0x6000)
    
    init() {
        // Inicializa com valores padrão
        reset()
    }
    
    // Conecta componentes
    func connectCPU(_ cpu: CPU65816) {
        self.cpu = cpu
    }
    
    func connectPPU(_ ppu: PPU) {
        self.ppu = ppu
    }
    
    func connectAPU(_ apu: APU) {
        self.apu = apu
    }
    
    // Carrega ROM
    func loadROM(data: Data) {
        self.rom = data
        
        // Debug: verifica o header da ROM
        print("ROM carregada: \(data.count) bytes")
        
        // Para LoROM, os vetores estão nos últimos 32 bytes da ROM
        if data.count >= 32 {
            let vectorBase = data.count - 32
            print("\nVetores de interrupção (offset na ROM):")
            
            // COP
            let copLow = data[vectorBase + 0x14]
            let copHigh = data[vectorBase + 0x15]
            let copVector = UInt16(copHigh) << 8 | UInt16(copLow)
            print("  COP:   \(String(format: "$%04X", copVector)) @ offset \(String(format: "$%06X", vectorBase + 0x14))")
            
            // BRK
            let brkLow = data[vectorBase + 0x16]
            let brkHigh = data[vectorBase + 0x17]
            let brkVector = UInt16(brkHigh) << 8 | UInt16(brkLow)
            print("  BRK:   \(String(format: "$%04X", brkVector)) @ offset \(String(format: "$%06X", vectorBase + 0x16))")
            
            // NMI
            let nmiLow = data[vectorBase + 0x1A]
            let nmiHigh = data[vectorBase + 0x1B]
            let nmiVector = UInt16(nmiHigh) << 8 | UInt16(nmiLow)
            print("  NMI:   \(String(format: "$%04X", nmiVector)) @ offset \(String(format: "$%06X", vectorBase + 0x1A))")
            
            // RESET
            let resetLow = data[vectorBase + 0x1C]
            let resetHigh = data[vectorBase + 0x1D]
            let resetVector = UInt16(resetHigh) << 8 | UInt16(resetLow)
            print("  RESET: \(String(format: "$%04X", resetVector)) @ offset \(String(format: "$%06X", vectorBase + 0x1C))")
            
            // IRQ/BRK
            let irqLow = data[vectorBase + 0x1E]
            let irqHigh = data[vectorBase + 0x1F]
            let irqVector = UInt16(irqHigh) << 8 | UInt16(irqLow)
            print("  IRQ:   \(String(format: "$%04X", irqVector)) @ offset \(String(format: "$%06X", vectorBase + 0x1E))")
            
            // Mostra os primeiros bytes no endereço de reset
            if resetVector != 0 && resetVector != 0xFFFF {
                print("\nPrimeiros bytes no endereço de RESET ($\(String(format: "%04X", resetVector))):")
                // Para LoROM, converte o endereço para offset na ROM
                let romOffset = Int(resetVector - 0x8000)
                for i in 0..<16 {
                    if romOffset + i < data.count {
                        let byte = data[romOffset + i]
                        print("  [\(String(format: "$%04X", resetVector + UInt16(i)))] = \(String(format: "$%02X", byte))")
                    }
                }
            }
        }
    }
    
    // Leitura de memória (8 bits)
    func read8(_ address: UInt32) -> UInt8 {
        let bank = (address >> 16) & 0xFF
        let offset = address & 0xFFFF
        
        switch bank {
        case 0x00...0x3F, 0x80...0xBF:
            // System Area
            switch offset {
            case 0x0000...0x1FFF:
                // WRAM (espelhado)
                return wram[Int(offset)]
                
            case 0x2000...0x21FF:
                // PPU registers (repetem a cada 8 bytes)
                return ppu?.readRegister(UInt16(0x2100 + (offset & 0x7))) ?? 0
                
            case 0x2200...0x3FFF:
                // DMA e outros registradores
                return ioRegisters[Int(offset - 0x2000)]
                
            case 0x4000...0x41FF:
                // APU e controles
                if offset <= 0x4003 {
                    return apu?.readRegister(UInt16(offset)) ?? 0
                }
                return ioRegisters[Int(offset - 0x2000)]
                
            case 0x4200...0x5FFF:
                // Mais registradores do sistema
                return ioRegisters[Int(offset - 0x2000)]
                
            case 0x6000...0x7FFF:
                // Expansão/Save RAM
                return sram[Int(offset - 0x6000)]
                
            case 0x8000...0xFFFF:
                // ROM (LoROM mapping)
                // Vetores de interrupção estão no final do banco
                if offset >= 0xFFE0 {
                    // Vetores de interrupção - lê do final da ROM
                    let vectorOffset = Int(offset - 0xFFE0)
                    let romVectorOffset = rom.count - 32 + vectorOffset
                    if romVectorOffset >= 0 && romVectorOffset < rom.count {
                        return rom[romVectorOffset]
                    }
                    return 0xFF
                }
                
                // Mapeamento normal da ROM
                let romBank = Int(bank & 0x7F)
                let romOffset = romBank * 0x8000 + Int(offset - 0x8000)
                if romOffset < rom.count {
                    return rom[romOffset]
                }
                return 0xFF
                
            default:
                return 0
            }
            
        case 0x40...0x7D, 0xC0...0xFF:
            // ROM Area (HiROM mapping)
            let romOffset = Int(bank) * 0x10000 + Int(offset)
            if romOffset < rom.count {
                return rom[romOffset]
            }
            return 0xFF
            
        case 0x7E...0x7F:
            // WRAM
            let wramOffset = Int(bank - 0x7E) * 0x10000 + Int(offset)
            return wram[wramOffset]
            
        default:
            return 0  // Open bus
        }
    }
    
    // Leitura de 16 bits (little-endian)
    func read16(_ address: UInt32) -> UInt16 {
        let low = UInt16(read8(address))
        let high = UInt16(read8(address + 1))
        return (high << 8) | low
    }
    
    // Escrita de memória (8 bits)
    func write8(_ address: UInt32, _ value: UInt8) {
        let bank = (address >> 16) & 0xFF
        let offset = address & 0xFFFF
        
        switch bank {
        case 0x00...0x3F, 0x80...0xBF:
            // System Area
            switch offset {
            case 0x0000...0x1FFF:
                // WRAM
                wram[Int(offset)] = value
                
            case 0x2100...0x21FF:
                // PPU registers
                ppu?.writeRegister(UInt16(offset), value)
                
            case 0x2200...0x3FFF:
                // DMA e outros
                ioRegisters[Int(offset - 0x2000)] = value
                handleDMA(UInt16(offset), value)
                
            case 0x4000...0x41FF:
                // APU e controles
                if offset <= 0x4003 {
                    apu?.writeRegister(UInt16(offset), value)
                } else {
                    ioRegisters[Int(offset - 0x2000)] = value
                }
                
            case 0x4200...0x5FFF:
                // Sistema
                ioRegisters[Int(offset - 0x2000)] = value
                
            case 0x6000...0x7FFF:
                // Save RAM
                sram[Int(offset - 0x6000)] = value
                
            default:
                // ROM area - não pode escrever
                break
            }
            
        case 0x7E...0x7F:
            // WRAM
            let wramOffset = (bank - 0x7E) * 0x10000 + offset
            wram[Int(wramOffset)] = value
            
        default:
            // ROM/Open bus - ignora escrita
            break
        }
    }
    
    // Escrita de 16 bits
    func write16(_ address: UInt32, _ value: UInt16) {
        write8(address, UInt8(value & 0xFF))
        write8(address + 1, UInt8((value >> 8) & 0xFF))
    }
    
    // Reset da memória
    func reset() {
        for i in 0..<wram.count {
            wram[i] = 0
        }
        for i in 0..<sram.count {
            sram[i] = 0
        }
        for i in 0..<ioRegisters.count {
            ioRegisters[i] = 0
        }
    }
    
    // Handle DMA transfers
    private func handleDMA(_ address: UInt16, _ value: UInt8) {
        // TODO: Implementar DMA
        // Por enquanto apenas placeholder
    }
    
    // Estado para save states
    struct State: Codable {
        let wram: [UInt8]
        let sram: [UInt8]
        let ioRegisters: [UInt8]
    }
    
    func getState() -> State {
        return State(
            wram: wram,
            sram: sram,
            ioRegisters: ioRegisters
        )
    }
    
    func setState(_ state: State) {
        wram = state.wram
        sram = state.sram
        ioRegisters = state.ioRegisters
    }
}
