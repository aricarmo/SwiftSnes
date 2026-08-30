// APU.swift
// SPC700 + IPL ROM + S-DSP, avançado pelo orçamento de ciclos do 65816 em SNES.runFrame().

import Foundation

final class APU {
    private static let masterPerCPUCycle = 8.0
    private static let masterClockHz = 21_477_272.0
    private static let spcClockHz = 2_048_000.0
    private static let spcCyclesPerDSPSample = spcClockHz / 32_000.0

    let spc700 = SPC700()
    let dsp = DSP()
    let audioOutput = AudioOutput()

    private var spcCycleDebt = 0.0
    private var dspCycleAccumulator = 0.0
    private var pendingAudioLeft: [Int16] = []
    private var pendingAudioRight: [Int16] = []

    init() {
        spc700.dsp = dsp
        dsp.readRAM = { [weak self] addr in
            self?.spc700.ram[Int(addr)] ?? 0
        }
        dsp.writeRAM = { [weak self] addr, val in
            self?.spc700.ram[Int(addr)] = val
        }
        pendingAudioLeft.reserveCapacity(1024)
        pendingAudioRight.reserveCapacity(1024)
        reset()
    }

    func reset() {
        for i in 0..<spc700.ram.count { spc700.ram[i] = 0 }
        spc700.reset()
        dsp.reset()
        spcCycleDebt = 0
        dspCycleAccumulator = 0
        pendingAudioLeft.removeAll(keepingCapacity: true)
        pendingAudioRight.removeAll(keepingCapacity: true)
    }

    // MARK: - Portas ($2140-$2143)

    func readPort(_ index: Int) -> UInt8 {
        spc700.portsToCPU[index & 3]
    }

    func writePort(_ index: Int, _ value: UInt8) {
        spc700.portsFromCPU[index & 3] = value
    }

    func readRegister(_ address: UInt16) -> UInt8 { readPort(Int(address & 3)) }
    func writeRegister(_ address: UInt16, _ value: UInt8) { writePort(Int(address & 3), value) }

    /// `count` is 65816 cycles (this emulator's unit: ~8 master clocks each).
    func step(cycles count: Int = 1) {
        guard count > 0 else { return }

        spcCycleDebt += Double(count) * Self.masterPerCPUCycle * Self.spcClockHz / Self.masterClockHz
        while spcCycleDebt >= 1.0 {
            let spcCycles = spc700.step()
            spc700.tickTimers(cpuCycles: spcCycles)
            runSPCCycles(spcCycles)
            spcCycleDebt -= Double(spcCycles)
        }
    }

    func flushAudio() {
        guard !pendingAudioLeft.isEmpty else { return }
        audioOutput.writeSamples(left: pendingAudioLeft, right: pendingAudioRight)
        pendingAudioLeft.removeAll(keepingCapacity: true)
        pendingAudioRight.removeAll(keepingCapacity: true)
    }

    func startAudio() {
        audioOutput.start()
    }

    func stopAudio() {
        flushAudio()
        audioOutput.stop()
    }

    /// Para com rampa de volume, evitando o estalo do buffer cortado no meio.
    func suspendAudio(fadeDuration: TimeInterval) {
        flushAudio()
        audioOutput.fadeOutAndStop(duration: fadeDuration)
    }

    private func runSPCCycles(_ cycles: Int) {
        guard !spc700.bootRomEnabled else { return }

        dspCycleAccumulator += Double(cycles)
        while dspCycleAccumulator >= Self.spcCyclesPerDSPSample {
            let sample = dsp.generateSample()
            pendingAudioLeft.append(sample.left)
            pendingAudioRight.append(sample.right)
            if pendingAudioLeft.count >= 1024 {
                flushAudio()
            }
            dspCycleAccumulator -= Self.spcCyclesPerDSPSample
        }
    }

    struct State: Codable {
        let ram: [UInt8]
        let portsFromCPU: [UInt8]
        let portsToCPU: [UInt8]
        let a: UInt8
        let x: UInt8
        let y: UInt8
        let sp: UInt8
        let pc: UInt16
        let psw: UInt8
        let dspAddr: UInt8
        let bootRomEnabled: Bool
        let stopped: Bool
        let sleeping: Bool
        let dspRegisters: [UInt8]
        let spcCycleDebt: Double
        let dspCycleAccumulator: Double
        let timerEnabled: [Bool]
        let timerDivisor: [UInt8]
        let timerCounter: [UInt8]
        let timerInternal: [UInt16]
    }

    func getState() -> State {
        State(
            ram: spc700.ram,
            portsFromCPU: spc700.portsFromCPU,
            portsToCPU: spc700.portsToCPU,
            a: spc700.a,
            x: spc700.x,
            y: spc700.y,
            sp: spc700.sp,
            pc: spc700.pc,
            psw: spc700.psw,
            dspAddr: spc700.dspAddr,
            bootRomEnabled: spc700.bootRomEnabled,
            stopped: spc700.stopped,
            sleeping: spc700.sleeping,
            dspRegisters: dsp.regs,
            spcCycleDebt: spcCycleDebt,
            dspCycleAccumulator: dspCycleAccumulator,
            timerEnabled: spc700.timerEnabled,
            timerDivisor: spc700.timerDivisor,
            timerCounter: spc700.timerCounter,
            timerInternal: spc700.timerInternal
        )
    }

    func setState(_ state: State) {
        reset()
        if state.ram.count == spc700.ram.count {
            spc700.ram = state.ram
        }
        spc700.portsFromCPU = state.portsFromCPU
        spc700.portsToCPU = state.portsToCPU
        spc700.a = state.a
        spc700.x = state.x
        spc700.y = state.y
        spc700.sp = state.sp
        spc700.pc = state.pc
        spc700.psw = state.psw
        spc700.dspAddr = state.dspAddr
        spc700.bootRomEnabled = state.bootRomEnabled
        spc700.stopped = state.stopped
        spc700.sleeping = state.sleeping
        if state.dspRegisters.count == dsp.regs.count {
            dsp.regs = state.dspRegisters
        }
        spcCycleDebt = state.spcCycleDebt
        dspCycleAccumulator = state.dspCycleAccumulator
        if state.timerEnabled.count == 3 {
            spc700.timerEnabled = state.timerEnabled
            spc700.timerDivisor = state.timerDivisor
            spc700.timerCounter = state.timerCounter
            spc700.timerInternal = state.timerInternal
        }
    }
}
