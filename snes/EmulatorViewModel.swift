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

    /// Frames do PPU. Fora do `@Published` de propósito: ver `ScreenView`.
    let frameSource = FrameSource()

    /// Nome curto que cabe ao lado do entalhe.
    var shortTitle: String {
        let cleaned = romTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "SNES" }
        return cleaned.uppercased()
    }

    /// Extensões aceitas no painel de abrir e no drop.
    static let romTypes: [UTType] = ["sfc", "smc", "fig", "swc"].compactMap { UTType(filenameExtension: $0) }

    /// NTSC: 21.477272 MHz / (1364 × 262) ≈ 60,0988 Hz.
    private static let frameDuration: TimeInterval = 1364.0 * 262.0 / 21_477_272.0

    private let snes = SNES()
    private let sramStore = SRAMStore()
    private var displayLink: CADisplayLink?
    private var frameAccumulator: TimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var fpsTimer: Timer?
    private var frameCount = 0
    private var lastFPSUpdate = Date()

    /// A ROM já foi ligada uma vez: retomar não pode resetar o console.
    private var poweredOn = false
    /// O painel quer o jogo rodando (aberto, fixado ou pausa automática desligada).
    private var presentationWantsRun = false
    /// Pausa explícita pelo botão, sobrepõe a apresentação.
    private var userPaused = false

    init() {
        startFPSTimer()
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
            let romData = try Data(contentsOf: url)
            try snes.loadROM(data: romData, firmwareDirectory: url.deletingLastPathComponent())
            if let sram = sramStore.load(romHash: snes.cartridgeHash) {
                snes.restoreSRAM(sram)
            }

            let cartTitle = snes.cartridgeTitle.trimmingCharacters(in: .whitespaces)
            romTitle = cartTitle.isEmpty ? url.deletingPathExtension().lastPathComponent : cartTitle
            errorText = nil
            isROMLoaded = true
            poweredOn = false
            userPaused = false

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
        applyRunState()
    }

    /// Chamado ao encerrar o app.
    func stopEmulation() {
        suspendEmulation()
        saveSRAMIfNeeded()
    }

    private func applyRunState() {
        let shouldRun = isROMLoaded && presentationWantsRun && !userPaused
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
        if let cgImage = snes.ppu.getFrameImage() {
            frameSource.publish(cgImage)
        }
        frameCount += 1
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
