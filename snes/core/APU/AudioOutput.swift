//  AudioOutput.swift
//  Saída de áudio via AVAudioSourceNode alimentada por um ring buffer SPSC
//  lock-free: o emulador (main) escreve, o thread realtime do CoreAudio lê.
//  Nenhum lock no callback de render — só loads/stores atômicos.

import AVFoundation
import Foundation
import Synchronization

final class AudioOutput {
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    // Ring buffer (potência de 2 para usar máscara em vez de `%`)
    private static let bufferSize = 32768  // amostras por canal
    private static let mask = bufferSize - 1
    private let prebufferSamples = 1536
    private let bufferL: UnsafeMutablePointer<Int16>
    private let bufferR: UnsafeMutablePointer<Int16>

    /// Só o produtor escreve `writePos`; só o consumidor escreve `readPos`.
    private let writePos = Atomic<Int>(0)
    private let readPos = Atomic<Int>(0)

    // Contadores de diagnóstico: cada um pertence a um único lado.
    private let underrunCount = Atomic<UInt64>(0)  // consumidor
    private let overrunCount = Atomic<UInt64>(0)   // produtor

    /// Volume do usuário (0…1) como bit pattern, lido pelo thread realtime.
    private let volumeBits = Atomic<UInt32>(Float(1).bitPattern)

    var volume: Float {
        get { Float(bitPattern: volumeBits.load(ordering: .relaxed)) }
        set { volumeBits.store(min(max(newValue, 0), 1).bitPattern, ordering: .relaxed) }
    }

    // Estado exclusivo do thread de áudio
    private var lastSampleL: Float = 0
    private var lastSampleR: Float = 0
    private var primed = false
    private let decayFactor: Float = 0.95

    private let sampleRate: Double = 32000.0
    private(set) var isRunning = false
    private var fadeTimer: Timer?

    init() {
        bufferL = .allocate(capacity: Self.bufferSize)
        bufferR = .allocate(capacity: Self.bufferSize)
        bufferL.initialize(repeating: 0, count: Self.bufferSize)
        bufferR.initialize(repeating: 0, count: Self.bufferSize)
    }

    deinit {
        stop()
        bufferL.deallocate()
        bufferR.deallocate()
    }

    // MARK: - Ciclo de vida

    func start() {
        guard !isRunning else { return }

        let engine = AVAudioEngine()
        self.engine = engine

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 2,
                                         interleaved: false) else {
            Log.audio.error("formato de áudio inválido")
            return
        }

        let sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            self.render(into: UnsafeMutableAudioBufferListPointer(audioBufferList), frames: Int(frameCount))
            return noErr
        }
        self.sourceNode = sourceNode

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
            isRunning = true
        } catch {
            Log.audio.error("falha ao iniciar a engine: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Rampa o volume até zero em `duration` e então para a engine.
    func fadeOutAndStop(duration: TimeInterval) {
        guard isRunning, duration > 0, let engine else {
            stop()
            return
        }

        fadeTimer?.invalidate()
        let steps = 10
        let interval = duration / Double(steps)
        let mixer = engine.mainMixerNode
        var remaining = steps

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            remaining -= 1
            mixer.outputVolume = Float(max(0, remaining)) / Float(steps)
            if remaining <= 0 {
                timer.invalidate()
                DispatchQueue.main.async {
                    self?.fadeTimer = nil
                    self?.stop()
                }
            }
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        engine?.mainMixerNode.outputVolume = 1
        // `engine.stop()` é síncrono: ao retornar o callback de render não roda
        // mais, então é seguro zerar o estado dos dois lados.
        engine?.stop()
        isRunning = false
        writePos.store(0, ordering: .releasing)
        readPos.store(0, ordering: .releasing)
        underrunCount.store(0, ordering: .relaxed)
        overrunCount.store(0, ordering: .relaxed)
        primed = false
        lastSampleL = 0
        lastSampleR = 0
    }

    // MARK: - Produtor (thread do emulador)

    /// Enfileira um lote estéreo. Descarta o excedente se o buffer encher.
    func writeSamples(left: [Int16], right: [Int16]) {
        guard !left.isEmpty, left.count == right.count else { return }

        var wp = writePos.load(ordering: .relaxed)              // só nós escrevemos
        let rp = readPos.load(ordering: .acquiring)
        let free = (rp &- wp &- 1) & Self.mask
        let count = min(free, left.count)
        if count < left.count {
            overrunCount.wrappingAdd(UInt64(left.count - count), ordering: .relaxed)
        }

        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                for i in 0..<count {
                    bufferL[wp] = l[i]
                    bufferR[wp] = r[i]
                    wp = (wp &+ 1) & Self.mask
                }
            }
        }
        writePos.store(wp, ordering: .releasing)
    }

    /// Amostras aproximadamente enfileiradas.
    var bufferedSamples: Int {
        let wp = writePos.load(ordering: .acquiring)
        let rp = readPos.load(ordering: .acquiring)
        return (wp &- rp) & Self.mask
    }

    /// Nível alvo do buffer para quem quiser sincronizar a emulação pelo áudio.
    var pacingTargetBufferedSamples: Int { prebufferSamples + prebufferSamples / 2 }

    var underrunEvents: UInt64 { underrunCount.load(ordering: .relaxed) }
    var overrunEvents: UInt64 { overrunCount.load(ordering: .relaxed) }

    // MARK: - Consumidor (thread realtime)

    private func render(into abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard abl.count >= 1, let raw0 = abl[0].mData else { return }
        let interleaved = abl.count == 1
        let channels = Int(abl[0].mNumberChannels)
        let out0 = raw0.assumingMemoryBound(to: Float.self)
        let out1 = (abl.count >= 2 ? abl[1].mData : nil)?.assumingMemoryBound(to: Float.self)

        @inline(__always) func put(_ frame: Int, _ l: Float, _ r: Float) {
            if interleaved {
                if channels >= 2 {
                    out0[frame * channels] = l
                    out0[frame * channels + 1] = r
                } else {
                    out0[frame] = (l + r) * 0.5
                }
            } else {
                out0[frame] = l
                out1?[frame] = r
            }
        }

        var rp = readPos.load(ordering: .relaxed)                 // só nós escrevemos
        let wp = writePos.load(ordering: .acquiring)
        let available = (wp &- rp) & Self.mask

        if !primed {
            if available < prebufferSamples {
                lastSampleL = 0
                lastSampleR = 0
                for f in 0..<frames { put(f, 0, 0) }
                return
            }
            primed = true
        }

        // Volume do usuário: lido uma vez por callback, aplicado na saída.
        // `lastSample*` fica pré-volume para o decay acompanhar mudanças.
        let vol = Float(bitPattern: volumeBits.load(ordering: .relaxed))

        let toRead = min(frames, available)
        for f in 0..<toRead {
            let l = Float(bufferL[rp]) / 32768.0
            let r = Float(bufferR[rp]) / 32768.0
            lastSampleL = l
            lastSampleR = r
            put(f, l * vol, r * vol)
            rp = (rp &+ 1) & Self.mask
        }
        readPos.store(rp, ordering: .releasing)

        guard toRead < frames else { return }
        primed = false
        underrunCount.wrappingAdd(1, ordering: .relaxed)
        // Underrun: decai a última amostra em vez de cortar para zero (evita estalo).
        for f in toRead..<frames {
            lastSampleL *= decayFactor
            lastSampleR *= decayFactor
            put(f, lastSampleL * vol, lastSampleR * vol)
        }
    }
}
