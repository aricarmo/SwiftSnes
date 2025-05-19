// EmulatorView.swift
import SwiftUI
import Combine

// MARK: - View Model
class EmulatorViewModel: ObservableObject {
    @Published var isROMLoaded = false
    @Published var isRunning = false
    @Published var statusText = "Nenhuma ROM carregada"
    @Published var fps: Double = 0
    @Published var frameImage: NSImage?
    
    private var snes: SNES?
    private var emulationTimer: Timer?
    private var fpsTimer: Timer?
    private var frameCount: Int = 0
    private var lastFPSUpdate = Date()
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        initializeEmulator()
        startFPSTimer()
        setupNotifications()
    }
    
    deinit {
        stopEmulation()
        fpsTimer?.invalidate()
    }
    
    private func initializeEmulator() {
        snes = SNES()
    }
    
    private func startFPSTimer() {
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.updateFPS()
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.publisher(for: Notification.Name("LoadROM"))
            .sink { _ in self.showFileDialog() }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: Notification.Name("TogglePlayPause"))
            .sink { _ in self.togglePlayPause() }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: Notification.Name("Reset"))
            .sink { _ in self.reset() }
            .store(in: &cancellables)
    }
    
    func showFileDialog() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Selecione uma ROM de SNES"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                self.loadROM(from: url)
            }
        }
    }
    
    func loadROM(from url: URL) {
        do {
            let romData = try Data(contentsOf: url)
            try snes?.loadROM(data: romData)
            
            statusText = "ROM carregada: \(url.lastPathComponent)"
            isROMLoaded = true
        } catch {
            statusText = "Erro ao carregar ROM: \(error.localizedDescription)"
        }
    }
    
    func togglePlayPause() {
        if isRunning {
            pauseEmulation()
        } else {
            startEmulation()
        }
    }
    
    func reset() {
        snes?.reset()
        statusText = "Sistema resetado"
    }
    
    private func startEmulation() {
        guard isROMLoaded else {
            print("Tentando iniciar sem ROM carregada")
            return
        }
        
        print("Iniciando emulação...")
        
        // IMPORTANTE: Liga o sistema antes de começar!
        snes?.powerOn()
        
        isRunning = true
        statusText = "Emulação em execução"
        
        emulationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { _ in
            self.runFrame()
        }
    }
    
    private func pauseEmulation() {
        emulationTimer?.invalidate()
        emulationTimer = nil
        
        isRunning = false
        statusText = "Emulação pausada"
    }
    
    func stopEmulation() {
        pauseEmulation()
    }
    
    private func runFrame() {
        guard let snes = snes else { return }
        
        snes.runFrame()
        updateScreen()
        frameCount += 1
    }
    
    private func updateScreen() {
        guard let snes = snes else { return }
        
        if let cgImage = snes.ppu.getFrameImage() {
            frameImage = NSImage(cgImage: cgImage, size: NSSize(width: 256, height: 224))
        }
    }
    
    private func updateFPS() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFPSUpdate)
        
        if elapsed >= 1.0 {
            fps = Double(frameCount) / elapsed
            frameCount = 0
            lastFPSUpdate = now
        }
    }
}

// MARK: - Screen View
struct ScreenView: NSViewRepresentable {
    let image: NSImage?
    
    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = false
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.layer?.magnificationFilter = .nearest  // Pixel perfect scaling
        return imageView
    }
    
    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = image
    }
}

// MARK: - Main View
struct EmulatorView: View {
    @StateObject private var viewModel = EmulatorViewModel()
    
    var body: some View {
        VStack(spacing: 0) {
            // Tela do emulador
            ScreenView(image: viewModel.frameImage)
                .frame(width: 512, height: 448)
                .background(Color.black)
                .border(Color.gray, width: 2)
            
            // Status bar
            HStack {
                Text(viewModel.statusText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("FPS: \(viewModel.fps, specifier: "%.1f")")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(viewModel.fps >= 59 ? .green : .orange)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            
            // Toolbar
            HStack(spacing: 16) {
                Button("Carregar ROM") {
                    viewModel.showFileDialog()
                }
                
                Divider()
                    .frame(height: 20)
                
                Button(viewModel.isRunning ? "Pausar" : "Iniciar") {
                    viewModel.togglePlayPause()
                }
                .disabled(!viewModel.isROMLoaded)
                .keyboardShortcut("p", modifiers: [])
                
                Button("Reset") {
                    viewModel.reset()
                }
                .disabled(!viewModel.isROMLoaded)
                .keyboardShortcut("r", modifiers: [])
                
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .focusable()
    }
}

// MARK: - Preview
#Preview {
    EmulatorView()
        .frame(width: 600, height: 550)
}
