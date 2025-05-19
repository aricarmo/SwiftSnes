// SNES.swift
import Foundation

class SNES {
    // Componentes principais
    var cpu: CPU65816
    var ppu: PPU
    var apu: APU
    var memory: MemoryBus
    
    // Estado do sistema
    var isRunning: Bool = false
    var totalCycles: UInt64 = 0
    
    // Clock do SNES (NTSC)
    let masterClockFrequency = 21_477_272  // ~21.477 MHz
    let cpuDivider = 12  // CPU roda a master_clock / 12
    
    init() {
        // Inicializa barramento de memória
        self.memory = MemoryBus()
        
        // Inicializa componentes
        self.cpu = CPU65816(memory: memory)
        self.ppu = PPU(memory: memory)
        self.apu = APU(memory: memory)
        
        // Conecta componentes ao barramento
        memory.connectCPU(cpu)
        memory.connectPPU(ppu)
        memory.connectAPU(apu)
    }
    
    // Carrega ROM do cartucho
    func loadROM(data: Data) throws {
        var romData = data
        
        // Detecta e remove header SMC se presente
        let hasHeader = (data.count % 0x8000) == 512
        if hasHeader {
            print("Header SMC detectado - removendo 512 bytes")
            romData = data.subdata(in: 512..<data.count)
        }
        
        // Verifica se a ROM tem pelo menos o tamanho mínimo
        guard romData.count >= 0x8000 else {
            throw EmulatorError.invalidROM
        }
        
        // Carrega a ROM na memória
        memory.loadROM(data: romData)
        
        // Reset do sistema após carregar a ROM
        reset()
    }
    
    // Executa um frame completo
    func runFrame() {
        guard isRunning else {
            print("runFrame chamado mas isRunning = false")
            return
        }
        
        
        // NTSC: 262 scanlines por frame
        for scanline in 0..<262 {
            // Cada scanline tem 1364 master cycles
            for _ in 0..<1364 {
                // CPU roda a cada 12 master cycles
                if totalCycles % UInt64(cpuDivider) == 0 {
                    cpu.step()
                }
                
                // PPU roda a cada 4 master cycles
                if totalCycles % 4 == 0 {
                    ppu.step()
                }
                
                // APU tem seu próprio timing
                apu.step()
                
                totalCycles += 1
            }
            
            // Fim da scanline
            ppu.endScanline(scanline)
        }
        
        // Fim do frame
        ppu.endFrame()
    }
    
    // Reset do sistema
    func reset() {
        cpu.reset()
        ppu.reset()
        apu.reset()
        memory.reset()
        totalCycles = 0
    }
    
    // Liga/desliga o sistema
    func powerOn() {
        reset()
        isRunning = true
        
        // Debug: mostra onde o CPU vai começar
        print("Sistema ligado. PC inicial: \(String(format: "$%04X", cpu.pc))")
    }
    
    func powerOff() {
        isRunning = false
    }
}

// Erro personalizado
enum EmulatorError: Error {
    case invalidROM
    case romLoadError
}


// Estado salvo para save states
extension SNES {
    struct SaveState: Codable {
        let cpuState: CPU65816.State
        let ppuState: PPU.State
        let apuState: APU.State
        let memoryState: MemoryBus.State
        let totalCycles: UInt64
    }
    
    func createSaveState() -> SaveState {
        return SaveState(
            cpuState: cpu.getState(),
            ppuState: ppu.getState(),
            apuState: apu.getState(),
            memoryState: memory.getState(),
            totalCycles: totalCycles
        )
    }
    
    func loadSaveState(_ state: SaveState) {
        cpu.setState(state.cpuState)
        ppu.setState(state.ppuState)
        apu.setState(state.apuState)
        memory.setState(state.memoryState)
        totalCycles = state.totalCycles
    }
}
