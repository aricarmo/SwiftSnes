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
    /// Cópia de cada lote de amostras (32 kHz, L/R) para quem quiser
    /// transmitir o áudio além da saída local. Chamado na thread da emulação.
    var onSamples: ((_ left: [Int16], _ right: [Int16]) -> Void)?

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
        onSamples?(pendingAudioLeft, pendingAudioRight)
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

    // MARK: - Save state

    func serialize(into w: inout StateWriter) {
        spc700.serialize(into: &w)
        dsp.serialize(into: &w)
        w.put(spcCycleDebt); w.put(dspCycleAccumulator)
    }

    func deserialize(from r: inout StateReader) throws {
        try spc700.deserialize(from: &r)
        try dsp.deserialize(from: &r)
        spcCycleDebt = try r.double(); dspCycleAccumulator = try r.double()
        pendingAudioLeft.removeAll(keepingCapacity: true)
        pendingAudioRight.removeAll(keepingCapacity: true)
    }
}
