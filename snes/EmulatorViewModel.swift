//  EmulatorViewModel.swift
//  View model do emulador: ciclo de vida da ROM, laço de frames e estado exibido no notch.

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EmulatorViewModel: ObservableObject {
    @Published var isROMLoaded = false
    @Published var isRunning = false
    @Published var romTitle = ""
    @Published var errorText: String?
    @Published var fps: Double = 0
    /// Um painel modal do próprio app está na frente: o notch não pode devolver o foco agora.
    @Published var isPresentingDialog = false
    /// Modo "voltar no tempo" aberto: jogo pausado, fita de miniaturas visível.
    @Published private(set) var rewind: RewindSession?
    /// Aviso de que o jogo continuou de um estado gravado; some sozinho.
    @Published private(set) var resumeNotice: ResumeNotice?

    struct RewindSession {
        /// Snapshots do mais antigo ao mais novo; o último é o "agora".
        var entries: [RewindHistory.Entry]
        /// Snapshot exibido na tela.
        var index: Int

        var latest: Int { entries.count - 1 }
        /// Quanto tempo atrás do "agora" está o snapshot exibido (≤ 0).
        var offsetSeconds: Double { -RewindHistory.seconds(from: index, to: latest) }
        /// Índice do snapshot mais próximo de `seconds` atrás do "agora", se existir.
        func index(secondsAgo seconds: Double) -> Int? {
            let steps = Int((seconds * 60.0988 / Double(RewindHistory.interval)).rounded())
            let i = latest - steps
            return i >= 0 ? i : nil
        }
    }

    struct ResumeNotice: Equatable {
        let savedAt: Date
    }

    /// Frames do PPU. Fora do `@Published` de propósito: ver `ScreenView`.
    let frameSource = FrameSource()

    /// Nome curto que cabe ao lado do entalhe.
    var shortTitle: String {
        let cleaned = romTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "SNES" }
        return cleaned.uppercased()
    }

    /// Extensões aceitas no painel de abrir e no drop.
    static let romTypes: [UTType] = ["sfc", "smc", "fig", "swc"].compactMap { UTType(filenameExtension: $0) } + [.zip]

    /// NTSC: 21.477272 MHz / (1364 × 262) ≈ 60,0988 Hz.
    private static let frameDuration: TimeInterval = 1364.0 * 262.0 / 21_477_272.0

    private let snes = SNES()
    private let sramStore = SRAMStore()
    private let stateStore = StateStore()
    private let history = RewindHistory()
    private var noticeWork: DispatchWorkItem?
    private var displayLink: CADisplayLink?
    private var frameAccumulator: TimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var fpsTimer: Timer?
    private var frameCount = 0
    private var lastFPSUpdate = Date()
    private var cancellables = Set<AnyCancellable>()

    /// A ROM já foi ligada uma vez: retomar não pode resetar o console.
    private var poweredOn = false
    /// O painel quer o jogo rodando (aberto, fixado ou pausa automática desligada).
    private var presentationWantsRun = false
    /// Pausa explícita pelo botão, sobrepõe a apresentação.
    private var userPaused = false

    init() {
        startFPSTimer()

        // Volume/mute valem na hora, inclusive com o jogo rodando.
        let settings = NotchSettings.shared
        settings.$volume.combineLatest(settings.$muted)
            .sink { [weak self] volume, muted in
                self?.snes.audioVolume = muted ? 0 : Float(volume)
            }
            .store(in: &cancellables)

        if let path = ProcessInfo.processInfo.environment["SNES_ROM"] {
            loadROM(from: URL(fileURLWithPath: path))
        }
    }

    // MARK: - ROM

    func showFileDialog() {
        NSApp.activate(ignoringOtherApps: true)
        isPresentingDialog = true

        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.romTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Selecione uma ROM de SNES"

        panel.begin { [weak self] response in
            guard let self else { return }
            isPresentingDialog = false
            if response == .OK, let url = panel.url {
                loadROM(from: url)
            }
        }
    }

    func loadROM(from url: URL) {
        // A ROM pode estar fora do sandbox; garante o acesso concedido pelo painel ou pelo drop.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Troca de jogo: o save do anterior não pode se perder.
        saveSRAMIfNeeded()
        suspendEmulation()

        do {
            let fileData = try Data(contentsOf: url)
            var romData = fileData
            var fallbackName = url.deletingPathExtension().lastPathComponent
            if ROMArchive.isZip(url) {
                let entry = try ROMArchive.extractROM(from: fileData)
                romData = entry.data
                fallbackName = (entry.name as NSString).deletingPathExtension
            }
            try snes.loadROM(data: romData, firmwareDirectory: url.deletingLastPathComponent())
            if let sram = sramStore.load(romHash: snes.cartridgeHash) {
                snes.restoreSRAM(sram)
            }

            let cartTitle = snes.cartridgeTitle.trimmingCharacters(in: .whitespaces)
            romTitle = cartTitle.isEmpty ? fallbackName : cartTitle
            errorText = nil
            isROMLoaded = true
            poweredOn = false
            userPaused = false
            rewind = nil
            history.clear()
            restoreSavedState()

            RecentROMs.shared.remember(url: url, title: romTitle)
            applyRunState()
        } catch {
            errorText = "Erro ao carregar ROM: \(error.localizedDescription)"
            isROMLoaded = false
        }
    }

    func loadRecent(_ entry: RecentROMs.Entry) {
        guard let url = RecentROMs.shared.resolve(entry) else {
            errorText = "Não foi possível reabrir \(entry.name)"
            return
        }
        loadROM(from: url)
    }

    // MARK: - Execução

    /// O painel informa se o jogo deveria estar rodando.
    func setPresentationRunning(_ shouldRun: Bool) {
        guard presentationWantsRun != shouldRun else { return }
        presentationWantsRun = shouldRun
        applyRunState()
    }

    func togglePlayPause() {
        userPaused.toggle()
        applyRunState()
    }

    func reset() {
        saveSRAMIfNeeded()
        snes.reset()
        userPaused = false
        rewind = nil
        history.clear()
        stateStore.remove(romHash: snes.cartridgeHash)
        dismissResumeNotice()
        applyRunState()
    }

    /// Chamado ao encerrar o app.
    func stopEmulation() {
        suspendEmulation()
        saveSRAMIfNeeded()
        saveStateForResume()
    }

    private func applyRunState() {
        let shouldRun = isROMLoaded && presentationWantsRun && !userPaused && rewind == nil
        if shouldRun {
            resumeEmulation()
        } else {
            suspendEmulation()
        }
    }

    private func resumeEmulation() {
        guard isROMLoaded, !isRunning else { return }

        if poweredOn {
            snes.resume()
        } else {
            snes.powerOn()   // powerOn reseta: só na primeira vez após carregar a ROM
            poweredOn = true
        }

        isRunning = true
        // Zera a janela de medição: senão o primeiro FPS após retomar
        // divide os frames novos pelo tempo em que estava pausado.
        frameCount = 0
        lastFPSUpdate = Date()
        startDisplayLink()
    }

    private func suspendEmulation() {
        guard isRunning else { return }
        stopDisplayLink()
        isRunning = false
        snes.suspend(fadeDuration: NotchSettings.shared.fadeDuration)
        saveSRAMIfNeeded()
        saveStateForResume()
    }

    // MARK: - Laço de frames

    /// Display link em vez de `Timer`: acorda em sincronia com o vsync e sem
    /// jitter. A tela pode ser 60 ou 120 Hz; o acumulador mantém o SNES nos
    /// seus 60,0988 Hz independentemente disso.
    private func startDisplayLink() {
        stopDisplayLink()
        let link = NotchMetrics.preferredScreen().displayLink(target: self, selector: #selector(displayTick(_:)))
        link.add(to: .main, forMode: .common)
        frameAccumulator = 0
        lastTick = 0
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTick = now }
        guard lastTick > 0 else {
            runFrame()
            return
        }
        // Se o app ficou parado (tracking de menu, sleep), não tenta "recuperar"
        // o atraso rodando dezenas de frames de uma vez.
        frameAccumulator += min(now - lastTick, Self.frameDuration * 2)
        var budget = 2
        while frameAccumulator >= Self.frameDuration && budget > 0 {
            frameAccumulator -= Self.frameDuration
            budget -= 1
            runFrame()
        }
    }

    private func runFrame() {
        snes.runFrame()
        let cgImage = snes.ppu.getFrameImage()
        if let cgImage {
            frameSource.publish(cgImage)
        }
        frameCount += 1
        history.frameDidRun { (snes.saveState(), cgImage) }
    }

    // MARK: - Voltar no tempo

    /// Pausa e abre a fita com os últimos segundos. Sem histórico não há o que mostrar.
    func enterRewind() {
        guard isROMLoaded, poweredOn, rewind == nil else { return }
        // O "agora" entra como último snapshot: cancelar volta exatamente para cá.
        history.append(state: snes.saveState(), image: snes.ppu.getFrameImage())
        rewind = RewindSession(entries: history.entries, index: history.count - 1)
        applyRunState()
    }

    /// Anda `delta` snapshots (negativo = para trás) e mostra o frame daquele momento.
    func rewindStep(_ delta: Int) {
        guard var session = rewind else { return }
        let target = max(0, min(session.latest, session.index + delta))
        guard target != session.index else { return }
        session.index = target
        rewind = session
        show(session.entries[target])
    }

    func rewindSelect(_ index: Int) {
        guard let session = rewind else { return }
        rewindStep(index - session.index)
    }

    /// Continua do snapshot exibido; o que veio depois dele é descartado.
    func rewindConfirm() {
        guard let session = rewind else { return }
        if load(session.entries[session.index]) {
            history.truncate(after: session.index)
            saveStateForResume()
        }
        rewind = nil
        applyRunState()
    }

    /// Fecha a fita e continua de onde o jogo estava.
    func rewindCancel() {
        guard let session = rewind else { return }
        _ = load(session.entries[session.latest])
        rewind = nil
        applyRunState()
    }

    func toggleRewind() {
        if rewind == nil { enterRewind() } else { rewindCancel() }
    }

    private func show(_ entry: RewindHistory.Entry) {
        if let image = entry.image {
            frameSource.publish(image)
        } else if load(entry), let image = snes.ppu.getFrameImage() {
            frameSource.publish(image)
        }
    }

    private func load(_ entry: RewindHistory.Entry) -> Bool {
        do {
            try snes.loadState(entry.state.decompressed())
            return true
        } catch {
            Log.saves.error("state do histórico inválido: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Retomar ao reabrir

    /// Ao carregar a ROM, continua do último estado gravado, se houver.
    private func restoreSavedState() {
        dismissResumeNotice()
        guard let saved = stateStore.load(romHash: snes.cartridgeHash) else { return }
        do {
            try snes.loadState(saved.state)
        } catch {
            Log.saves.warning("state salvo ignorado: \(String(describing: error), privacy: .public)")
            stateStore.remove(romHash: snes.cartridgeHash)
            snes.reset()
            return
        }
        // O console já está no meio do jogo: retomar não pode ligar (resetar) de novo.
        poweredOn = true
        if let image = snes.ppu.getFrameImage() {
            frameSource.publish(image)
        }
        resumeNotice = ResumeNotice(savedAt: saved.savedAt)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.resumeNotice = nil }
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func dismissResumeNotice() {
        noticeWork?.cancel()
        noticeWork = nil
        if resumeNotice != nil { resumeNotice = nil }
    }

    private func saveStateForResume() {
        guard isROMLoaded, poweredOn else { return }
        do {
            try stateStore.save(snes.saveState(), romHash: snes.cartridgeHash)
        } catch {
            Log.saves.error("falha ao gravar .nss: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - FPS

    private func startFPSTimer() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFPS() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fpsTimer = timer
    }

    private func updateFPS() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFPSUpdate)
        guard elapsed >= 1.0 else { return }
        fps = isRunning ? Double(frameCount) / elapsed : 0
        frameCount = 0
        lastFPSUpdate = now
    }

    // MARK: - SRAM

    private func saveSRAMIfNeeded() {
        guard isROMLoaded, snes.sramNeedsSave else { return }
        do {
            try sramStore.save(snes.sram, romHash: snes.cartridgeHash)
            snes.markSRAMSaved()
        } catch {
            Log.saves.error("falha ao gravar .srm: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Entrada

    func setJoypad(_ state: UInt16) {
        snes.setJoypad(0, state: state)
    }
}
