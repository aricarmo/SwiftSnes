// SNES.swift
import Foundation

final class SNES {
    var cpu: CPU65816
    public var ppu: PPU
    var apu: APU
    var memory: MemoryBus

    var isRunning: Bool = false
    var totalCycles: UInt64 = 0

    let masterClockFrequency = 21_477_272  // ~21.477 MHz

    /// Um ciclo de CPU equivale a ~2 dots do PPU (8 vs 4 master cycles)
    private let dotsPerCPUCycle = 2

    /// Trava de segurança: se o CPU travar num loop sem avançar o PPU
    private let maxStepsPerFrame = 400_000
    private var reportedTruncatedFrame = false

    init() {
        self.memory = MemoryBus()

        self.cpu = CPU65816(memory: memory)
        self.ppu = PPU(memory: memory)
        self.apu = APU()

        memory.connectCPU(cpu)
        memory.connectPPU(ppu)
        memory.connectAPU(apu)

        ppu.connectCPU(cpu)
    }

    deinit {
        apu.stopAudio()
        memory.disconnect()
    }

    func loadROM(data: Data, firmwareDirectory: URL? = nil) throws {
        try memory.loadROM(data: data, firmwareDirectory: firmwareDirectory)
        reset()
    }

    var cartridgeTitle: String { memory.cart.title }
    var cartridgeMapper: String { memory.cart.mapper.description }
    var cartridgeHash: String { memory.cart.romHash }

    // MARK: - SRAM

    var sramNeedsSave: Bool { memory.cart.sramDirty }
    var sram: [UInt8] { memory.cart.sram }

    func restoreSRAM(_ data: [UInt8]) { memory.cart.setSRAM(data) }
    func markSRAMSaved() { memory.cart.markSRAMClean() }

    // MARK: - Controles

    /// Atualiza o estado de um controle. Formato: B Y Sel Sta Up Dn Lf Rt A X L R 0 0 0 0
    func setJoypad(_ index: Int, state: UInt16) {
        guard index >= 0 && index < 4 else { return }
        memory.joypadState[index] = state
    }

    // MARK: - Execução

    /// Executa até o PPU completar um frame.
    func runFrame() {
        guard isRunning else { return }

        memory.resetDMACycles()

        var frameDone = false
        var steps = 0

        while !frameDone && steps < maxStepsPerFrame {
            let cpuCycles = cpu.step()

            let stolen = memory.dmaCycles
            memory.resetDMACycles()

            let totalCycles = cpuCycles + stolen

            if ppu.step(dots: totalCycles * dotsPerCPUCycle) {
                frameDone = true
            }

            apu.step(cycles: totalCycles)
            memory.advanceCartDSP(cpuCycles: totalCycles)

            self.totalCycles &+= UInt64(totalCycles)
            steps += 1
        }

        if steps >= maxStepsPerFrame && !reportedTruncatedFrame {
            reportedTruncatedFrame = true
            Log.emulator.error("frame truncado em \(steps) instruções sem o PPU terminar; CPU em $\(String(format: "%02X:%04X", self.cpu.pb, self.cpu.pc), privacy: .public)")
        }

        apu.flushAudio()
    }

    func reset() {
        memory.reset()
        ppu.reset()
        apu.reset()
        cpu.reset()   // por último: precisa ler o vetor de reset já com tudo no lugar
        totalCycles = 0
        reportedTruncatedFrame = false
    }

    func powerOn() {
        reset()
        isRunning = true
        apu.startAudio()
    }

    func powerOff() {
        isRunning = false
        apu.stopAudio()
    }

    /// Suspende sem resetar: usado quando o painel do notch recolhe.
    func suspend(fadeDuration: TimeInterval = 0.15) {
        guard isRunning else { return }
        isRunning = false
        apu.suspendAudio(fadeDuration: fadeDuration)
    }

    /// Retoma exatamente de onde parou.
    func resume() {
        guard !isRunning else { return }
        isRunning = true
        apu.startAudio()
    }
}

enum EmulatorError: Error, LocalizedError {
    case invalidROM
    case romLoadError

    var errorDescription: String? {
        switch self {
        case .invalidROM:   return "Arquivo não parece ser uma ROM de SNES válida"
        case .romLoadError: return "Falha ao ler o arquivo da ROM"
        }
    }
}

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
