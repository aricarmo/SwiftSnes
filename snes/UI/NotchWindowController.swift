//  NotchWindowController.swift
//  NSPanel sem foco ancorado no topo da tela, dimensionado pelo conteúdo SwiftUI.

import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchWindowController {
    private let panel: NotchPanel
    private let hostingController: NSHostingController<NotchRootView>
    private let measuringController: NSHostingController<NotchRootView>
    private let viewModel: EmulatorViewModel
    private let settings = NotchSettings.shared
    private let presenter: NotchPresenter
    private let bindings = KeyBindings.shared
    private let padBindings = GamepadBindings.shared
    private let gamepad = GamepadInput()

    private var hoverMonitor: NotchHoverMonitor?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var pinHotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()
    private var previousApp: NSRunningApplication?
    private var pressedButtons: UInt16 = 0
    private var hadROM = false
    /// Altura do conteúdo desenhado. A janela pode estar maior que isso enquanto anima.
    private var contentHeight: CGFloat = 0
    /// Última altura aberta medida. O painel recolhido também precisa saber que
    /// ela mudou, senão reabre com a moldura do conteúdo antigo.
    private var expandedHeight: CGFloat = 0
    private var shrinkWork: DispatchWorkItem?
    /// Retomada adiada do jogo: só depois de o painel terminar de expandir.
    private var resumeWork: DispatchWorkItem?

    private var screen: NSScreen { NotchMetrics.preferredScreen() }
    private var panelWidth: CGFloat { NotchMetrics.panelWidth(on: screen) }
    private var headerHeight: CGFloat { NotchMetrics.headerHeight(on: screen) }
    /// Largura máxima do painel (corpo com o jogo). A janela é sempre desse
    /// tamanho; o conteúdo mais estreito fica centralizado nela.
    private var bodyWidth: CGFloat { NotchMetrics.bodyWidth(panelWidth: panelWidth, size: settings.screenSize) }

    init(viewModel: EmulatorViewModel) {
        self.viewModel = viewModel
        presenter = NotchPresenter(settings: settings)

        let currentScreen = NotchMetrics.preferredScreen()
        let width = NotchMetrics.panelWidth(on: currentScreen)
        let header = NotchMetrics.headerHeight(on: currentScreen)
        let body = NotchMetrics.bodyWidth(panelWidth: width, size: settings.screenSize)

        let root = NotchRootView(
            vm: viewModel,
            presenter: presenter,
            settings: settings,
            bindings: bindings,
            padBindings: padBindings,
            gamepad: gamepad,
            recents: RecentROMs.shared,
            panelWidth: width,
            headerHeight: header,
            notchGap: NotchMetrics.notchWidth(on: currentScreen),
            onQuit: { NSApp.terminate(nil) }
        )
        var measuringRoot = root
        measuringRoot.measuring = true
        measuringController = NSHostingController(rootView: measuringRoot)

        // Mede antes de montar a view real: assim ela já nasce com a altura
        // final e a primeira exibição não anima.
        var liveRoot = root
        let natural = measuringController.sizeThatFits(
            in: CGSize(width: body, height: .greatestFiniteMagnitude)
        ).height
        liveRoot.naturalHeight = natural
        liveRoot.visibleHeight = natural
        hostingController = NSHostingController(rootView: liveRoot)
        // O tamanho da janela é nosso: o controller não deve forçar o dele.
        hostingController.sizingOptions = []

        panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: body + NotchMetrics.shadowMargin * 2,
                                height: header + NotchMetrics.shadowMargin),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // A hosting view fica dentro de um container, e não como contentView
        // direto: como contentView o NSHostingView redimensiona a janela sozinho
        // (`updateAnimatedWindowSize`) quando o tamanho ideal do conteúdo muda —
        // ao trocar o tamanho de tela nos ajustes ele alargava a janela mantendo
        // o X, e o painel saía do centro do notch. A geometria é só nossa.
        let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        hostingController.view.frame = container.bounds
        hostingController.view.autoresizingMask = [.width, .height]
        container.addSubview(hostingController.view)
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Sem sombra: junto dela o macOS desenha o hairline claro na moldura da
        // janela, e a borda quebra a ilusão de o painel ser o próprio notch.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        presenter.hasROM = viewModel.isROMLoaded
        presenter.hasGamepad = gamepad.isConnected
        presenter.isAppActive = NSApp.isActive

        observeState()
        observeActivation()
        installHoverMonitor()
        installKeyMonitor()
        installClickMonitor()
        installHotKey()
        observeGamepad()
    }

    func show() {
        layout(animated: false)
        panel.orderFrontRegardless()
        syncEmulation()
    }

    /// O controller vive enquanto o app; quem o descartar deve chamar isto.
    func invalidate() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
        hoverMonitor?.invalidate()
        pinHotKey?.invalidate()
    }

    // MARK: - Geometria

    private var hotRect: NSRect {
        // Região quente: o conteúdo visível (não a janela, que fica maior enquanto
        // anima), com folga de 4 pt para o cursor não escapar na borda.
        let frame = panel.frame
        // Recolhido, a faixa tem só a largura do notch: a região quente
        // acompanha, senão passar o mouse na barra de menus ao lado já abriria.
        let width = presenter.showsHeader
            ? bodyWidth
            : NotchMetrics.collapsedWidth(panelWidth: panelWidth,
                                          notchGap: NotchMetrics.notchWidth(on: screen))
        return NSRect(x: frame.midX - width / 2, y: frame.maxY - contentHeight,
                      width: width, height: contentHeight)
            .insetBy(dx: -4, dy: -4)
    }

    /// O painel é sempre desenhado inteiro e recortado a partir do topo; quem
    /// anima é esse recorte. A janela apenas comporta o movimento: cresce antes
    /// e só encolhe depois, senão cortaria o conteúdo no meio da animação.
    private func layout(animated: Bool) {
        // Altura natural do painel aberto, medida fora da janela.
        let fitting = measuringController.sizeThatFits(
            in: CGSize(width: bodyWidth, height: .greatestFiniteMagnitude)
        ).height
        let expanded = max(headerHeight, fitting.isFinite && fitting > 0 ? fitting : headerHeight)
        let target = presenter.isOpen ? expanded : headerHeight
        guard target != contentHeight || expanded != expandedHeight
                || panel.frame.width != bodyWidth + NotchMetrics.shadowMargin * 2 else { return }
        expandedHeight = expanded
        contentHeight = target
        hostingController.rootView.naturalHeight = expanded

        shrinkWork?.cancel()
        guard animated else {
            hostingController.rootView.visibleHeight = target
            setPanelHeight(target)
            return
        }

        // Primeiro a janela cresce, depois a máscara anima: se a mudança do
        // rootView for desenhada dentro do setFrame, o SwiftUI não a anima.
        setPanelHeight(max(target, panel.frame.height - NotchMetrics.shadowMargin))
        // No ciclo seguinte: junto com a mudança de bounds do NSHostingView a
        // atualização é coalescida numa transação sem animação.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.contentHeight == target else { return }
                withAnimation(NotchMetrics.contentAnimation) {
                    self.hostingController.rootView.visibleHeight = target
                }
            }
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.contentHeight == target else { return }
                self.setPanelHeight(target)
            }
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.expandDuration + 0.02,
                                      execute: work)
    }

    private func setPanelHeight(_ height: CGFloat) {
        let margin = NotchMetrics.shadowMargin
        // A janela fica sempre na altura expandida: o NSHostingView não desenha
        // conteúdo que transborda a janela, e o painel recolhido (37 pt) ficava
        // invisível. Quem recolhe é só a máscara; o resto da janela é
        // transparente e deixa cliques passarem.
        let windowHeight = max(height, expandedHeight)
        let frame = NSRect(
            x: (screen.frame.midX - bodyWidth / 2).rounded() - margin,
            y: screen.frame.maxY - windowHeight - margin,
            width: bodyWidth + margin * 2,
            height: windowHeight + margin
        )
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }

    // MARK: - Estado

    private func observeState() {
        // Só o que muda o tamanho ou o estado do painel. Os frames do jogo nem
        // passam por aqui: vão direto ao CALayer via `FrameSource`.
        Publishers.MergeMany(
            viewModel.$isROMLoaded.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isRunning.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$errorText.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isPresentingDialog.map { _ in () }.eraseToAnyPublisher(),
            presenter.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            bindings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            padBindings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            gamepad.$controller.map { _ in () }.eraseToAnyPublisher(),
            gamepad.$batteryLevel.map { _ in () }.eraseToAnyPublisher(),
            gamepad.$justConnected.map { _ in () }.eraseToAnyPublisher(),
            RecentROMs.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        )
        // `objectWillChange` dispara antes da mutação: adia um ciclo para ler o
        // estado já atualizado.
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.stateChanged() }
        .store(in: &cancellables)
    }

    private func observeActivation() {
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.presenter.isAppActive = true }
            .store(in: &cancellables)
        center.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.presenter.isAppActive = false }
            .store(in: &cancellables)
    }

    private func stateChanged() {
        // ROM recém-carregada: já entra fixado, senão o jogo pausaria assim que o cursor saísse.
        if viewModel.isROMLoaded && !hadROM {
            presenter.isPinned = true
        }
        hadROM = viewModel.isROMLoaded
        // Só atribui quando muda: @Published notifica mesmo com valor igual,
        // e a notificação volta para cá em laço.
        if presenter.hasROM != viewModel.isROMLoaded {
            presenter.hasROM = viewModel.isROMLoaded
        }
        layout(animated: true)
        syncEmulation()
        syncFocus()
    }

    /// Pausar é imediato; retomar espera a animação de expansão terminar, senão
    /// o jogo anda enquanto a tela ainda está escondida e o jogador perde um
    /// momento crítico sem ver.
    private func syncEmulation() {
        resumeWork?.cancel()
        resumeWork = nil
        let shouldRun = presenter.shouldRun
        guard shouldRun else {
            viewModel.setPresentationRunning(false)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presenter.shouldRun else { return }
                self.viewModel.setPresentationRunning(true)
            }
        }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.expandDuration + 0.05,
                                      execute: work)
    }

    /// Teclado só é capturado com o app ativo — por isso hover, fixar e abrir
    /// ajustes ativam o app. O monitor local só vê eventos entregues a nós.
    private func syncFocus() {
        guard !viewModel.isPresentingDialog else { return }
        let needsKeyboard = presenter.needsKeyboard
        if needsKeyboard, !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else if !needsKeyboard, NSApp.isActive {
            // Soltando o teclado: zera o joypad, senão a tecla presa na saída
            // fica marcada até o próximo keyUp que nunca chega.
            releaseJoypad()
            let previous = previousApp
            previousApp = nil
            panel.resignKey()
            previous?.activate(options: [])
        }
    }

    private func releaseJoypad() {
        guard pressedButtons != 0 else { return }
        pressedButtons = 0
        pushJoypad()
    }

    /// Teclado e controle somam: soltar um não apaga o outro.
    private func pushJoypad() {
        viewModel.setJoypad(pressedButtons | gamepad.pressed)
    }

    private func observeGamepad() {
        // Direto no evento, sem passar por Combine/SwiftUI: latência mínima.
        gamepad.onPressedChange = { [weak self] _ in
            guard let self, presenter.rebindingPadButton == nil, !presenter.showsSettings else { return }
            pushJoypad()
        }
        gamepad.$controller
            .receive(on: DispatchQueue.main)
            .sink { [weak self] controller in
                guard let self else { return }
                presenter.hasGamepad = controller != nil
                if controller == nil { presenter.rebindingPadButton = nil }
            }
            .store(in: &cancellables)
        presenter.$rebindingPadButton
            .sink { [weak self] button in
                // Só captura enquanto há algo a regravar; fora disso o handler é nil e o jogo recebe o controle.
                guard let self else { return }
                if button == nil { gamepad.onCapture = nil } else { installCapture() }
            }
            .store(in: &cancellables)
    }

    private func installCapture() {
        gamepad.onCapture = { [weak self] element in
            guard let self, let button = presenter.rebindingPadButton else { return }
            padBindings.bind(button, to: element)
            presenter.rebindingPadButton = nil
        }
    }

    // MARK: - Monitores

    private func installHoverMonitor() {
        hoverMonitor = NotchHoverMonitor { [weak self] location in
            guard let self else { return }
            if settings.clickToOpen && !presenter.isOpen { return }
            presenter.cursorInsideChanged(hotRect.contains(location))
        }
    }

    /// A janela não é key enquanto só se espia o painel, e o primeiro clique numa
    /// janela inativa apenas a torna key — o gesto do SwiftUI só veria o segundo.
    /// O monitor local recebe o mouseDown de qualquer forma e expande de primeira.
    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, event.window === panel, !presenter.isOpen,
                  hotRect.contains(NSEvent.mouseLocation) else { return event }
            presenter.openImmediately()
            return nil
        }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Regravando uma tecla: captura a próxima e devolve o teclado ao jogo.
        if let button = presenter.rebindingButton {
            guard event.type == .keyDown else { return nil }
            if event.keyCode == UInt16(kVK_Escape) {
                presenter.rebindingButton = nil
                return nil
            }
            bindings.bind(button, to: event.keyCode)
            presenter.rebindingButton = nil
            return nil
        }

        if event.type == .keyDown && event.keyCode == UInt16(kVK_Escape) {
            if presenter.rebindingPadButton != nil {
                presenter.rebindingPadButton = nil
            } else if presenter.showsSettings {
                presenter.showsSettings = false
            } else if presenter.isPinned {
                presenter.isPinned = false
            }
            return nil
        }

        guard presenter.needsKeyboard, !presenter.showsSettings,
              let button = bindings.map[event.keyCode] else { return event }

        if event.type == .keyDown {
            pressedButtons |= button.mask
        } else {
            pressedButtons &= ~button.mask
        }
        pushJoypad()
        return nil
    }

    private func installHotKey() {
        pinHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.presenter.togglePin()
        }
    }
}
