//  NotchRootView.swift
//  Raiz do painel que se funde ao notch: aplica máscara, sombra, gestos e
//  troca o corpo (jogo, vazio, ajustes). As seções vivem em UI/Notch/.

import SwiftUI

struct NotchRootView: View {
    @ObservedObject var vm: EmulatorViewModel
    @ObservedObject var presenter: NotchPresenter
    @ObservedObject var settings: NotchSettings
    @ObservedObject var bindings: KeyBindings
    @ObservedObject var padBindings: GamepadBindings
    @ObservedObject var gamepad: GamepadInput
    @ObservedObject var recents: RecentROMs
    @ObservedObject var library: GameLibrary
    @ObservedObject var updater: UpdateChecker

    let panelWidth: CGFloat
    let headerHeight: CGFloat
    let notchGap: CGFloat
    let onQuit: () -> Void

    /// Cópia usada só para medir: sem recorte nem esticada até o fundo da
    /// janela, devolve a altura natural do conteúdo aberto.
    var measuring = false
    /// Altura do painel aberto. Fixa: o conteúdo nunca muda de tamanho.
    var naturalHeight: CGFloat = 0
    /// Altura revelada pela máscara. É só ela que anima, ancorada no topo —
    /// por isso o painel desce e sobe em vez de crescer pelo centro.
    var visibleHeight: CGFloat = 0

    private var videoSize: CGSize {
        NotchMetrics.videoSize(panelWidth: panelWidth, size: settings.screenSize)
    }
    /// Largura do corpo com o jogo.
    private var bodyWidth: CGFloat {
        NotchMetrics.bodyWidth(panelWidth: panelWidth, size: settings.screenSize)
    }
    /// Largura máxima do painel (jogo ou biblioteca). É a largura da janela.
    private var windowWidth: CGFloat {
        NotchMetrics.windowWidth(panelWidth: panelWidth, size: settings.screenSize)
    }
    /// Sem ROM e com jogos recentes, o corpo é o carrossel.
    private var showsLibrary: Bool { !vm.isROMLoaded && !library.items.isEmpty }
    /// Largura do corpo exibido agora: jogo e biblioteca alargam; vazio e
    /// ajustes ficam na largura da faixa do notch.
    private var currentBodyWidth: CGFloat {
        if presenter.showsSettings { return panelWidth }
        if vm.isROMLoaded { return bodyWidth }
        return showsLibrary ? NotchMetrics.libraryBodyWidth : panelWidth
    }
    /// Largura da faixa exibida agora: recolhida, cobre só o entalhe físico
    /// (em Macs sem notch não há entalhe, então fica na largura do painel);
    /// com o cursor em cima alarga para caber título e FPS, e aberta acompanha
    /// o corpo, sem ombros.
    private var currentHeaderWidth: CGFloat {
        if presenter.isOpen { return currentBodyWidth }
        return presenter.showsHeader
            ? panelWidth
            : NotchMetrics.collapsedWidth(panelWidth: panelWidth, notchGap: notchGap)
    }
    /// Faixa do notch em cima, corpo (possivelmente mais largo) embaixo.
    private var shape: NotchPanelShape {
        NotchPanelShape(headerWidth: currentHeaderWidth, headerHeight: headerHeight,
                        bodyWidth: currentBodyWidth)
    }

    init(vm: EmulatorViewModel, presenter: NotchPresenter, settings: NotchSettings,
         bindings: KeyBindings, padBindings: GamepadBindings, gamepad: GamepadInput,
         recents: RecentROMs, library: GameLibrary, updater: UpdateChecker,
         panelWidth: CGFloat, headerHeight: CGFloat, notchGap: CGFloat,
         onQuit: @escaping () -> Void) {
        self.vm = vm
        self.presenter = presenter
        self.settings = settings
        self.bindings = bindings
        self.padBindings = padBindings
        self.gamepad = gamepad
        self.recents = recents
        self.library = library
        self.updater = updater
        self.panelWidth = panelWidth
        self.headerHeight = headerHeight
        self.notchGap = notchGap
        self.onQuit = onQuit
    }

    /// Abrir em duas etapas: a faixa alarga primeiro e o corpo só desce depois.
    private var heightAnimation: Animation {
        presenter.isOpen
            ? NotchMetrics.contentAnimation.delay(NotchMetrics.expandHeightDelay)
            : NotchMetrics.contentAnimation
    }
    /// Fechar é o inverso: enquanto o corpo ainda está descido (a máscara só
    /// muda no ciclo seguinte), a faixa espera ele subir antes de estreitar.
    /// No hover, sem corpo, alarga e estreita na hora.
    private var widthAnimation: Animation {
        let closing = !presenter.isOpen && visibleHeight > headerHeight + 0.5
        return closing
            ? NotchMetrics.widthAnimation.delay(NotchMetrics.collapseWidthDelay)
            : NotchMetrics.widthAnimation
    }

    var body: some View {
        // Árvore estável: a cópia de medição só deixa de aplicar o recorte.
        panelContent
            .modifier(PanelChrome(enabled: !measuring,
                                  shape: shape,
                                  heightAnimation: heightAnimation,
                                  widthAnimation: widthAnimation,
                                  bodyWidth: windowWidth,
                                  naturalHeight: naturalHeight,
                                  visibleHeight: visibleHeight,
                                  currentBodyWidth: currentBodyWidth,
                                  currentHeaderWidth: currentHeaderWidth,
                                  showsShadow: presenter.showsShadow,
                                  onTap: openIfCollapsed,
                                  onDrop: handleDrop,
                                  contextMenu: contextMenuItems))
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            // Aberto, título e FPS se espalham pela largura do corpo.
            NotchHeader(vm: vm, presenter: presenter, gamepad: gamepad, updater: updater,
                        panelWidth: presenter.isOpen ? currentBodyWidth : panelWidth,
                        headerHeight: headerHeight, notchGap: notchGap)
            // ZStack e não o if/else solto no VStack: enquanto a troca de corpo
            // anima, o SwiftUI mantém a view que sai ocupando lugar no layout.
            // Empilhadas, as duas somariam altura, a pilha estouraria a moldura
            // de `naturalHeight` e o conteúdo subiria para fora do topo antes de
            // assentar. Sobrepostas, a troca é só um crossfade e a altura
            // acompanha a máscara.
            ZStack(alignment: .top) {
                if presenter.showsSettings {
                    SettingsBody(presenter: presenter, settings: settings, bindings: bindings,
                                 padBindings: padBindings, gamepad: gamepad, updater: updater,
                                 panelWidth: panelWidth, onChooseFolder: vm.showFolderDialog, onQuit: onQuit)
                        .transition(.opacity)
                } else if vm.isROMLoaded {
                    GameBody(vm: vm, presenter: presenter, gamepad: gamepad,
                             videoSize: videoSize, filter: settings.screenFilter)
                        .transition(.opacity)
                } else if showsLibrary {
                    LibraryBody(vm: vm, library: library, gamepad: gamepad, updater: updater,
                                bodyWidth: NotchMetrics.libraryBodyWidth)
                        .transition(.opacity)
                } else {
                    EmptyDropBody(vm: vm, presenter: presenter, updater: updater, panelWidth: panelWidth)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: windowWidth, alignment: .top)
        // Fundo sobra de cada lado para as orelhas do topo da faixa.
        .padding(.horizontal, NotchMetrics.topFlareRadius)
        .background(NotchPalette.panel)
    }

    @ViewBuilder
    private func contextMenuItems() -> some View {
        Button(presenter.isPinned ? "Soltar painel" : "Fixar painel", action: presenter.togglePin)
        Button("Carregar ROM…", action: vm.showFileDialog)
        if vm.isROMLoaded {
            Button("Voltar à biblioteca", action: vm.ejectROM)
        }
        Divider()
        Button("Sair", action: onQuit)
    }

    // MARK: - Ações

    private func openIfCollapsed() {
        if !presenter.isOpen { presenter.openImmediately() }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let vm = self.vm
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in vm.loadROM(from: url) }
        }
        return true
    }
}

/// Máscara, sombra, gestos e margem da janela. Desligado na cópia de medição.
private struct PanelChrome<Menu: View>: ViewModifier {
    let enabled: Bool
    let shape: NotchPanelShape
    let heightAnimation: Animation
    let widthAnimation: Animation
    let bodyWidth: CGFloat
    let naturalHeight: CGFloat
    let visibleHeight: CGFloat
    let currentBodyWidth: CGFloat
    let currentHeaderWidth: CGFloat
    let showsShadow: Bool
    let onTap: () -> Void
    let onDrop: ([NSItemProvider]) -> Bool
    @ViewBuilder let contextMenu: () -> Menu

    func body(content: Content) -> some View {
        // Largura do conteúdo com a folga das orelhas de cada lado.
        let flare = NotchMetrics.topFlareRadius
        let width = bodyWidth + flare * 2
        if enabled {
            content
                // Altura constante: animar layout faria o conteúdo crescer do
                // centro. Só a máscara muda, e ela cresce a partir do topo.
                .frame(height: naturalHeight, alignment: .top)
                .mask(alignment: .top) {
                    shape.frame(width: width, height: visibleHeight)
                }
                .animation(heightAnimation, value: visibleHeight)
                .animation(NotchMetrics.contentAnimation, value: currentBodyWidth)
                .animation(widthAnimation, value: currentHeaderWidth)
                // Sombra desenhada aqui (a nativa traria o hairline da janela).
                // Duas camadas: uma justa e escura, outra ampla e difusa.
                .shadow(color: .black.opacity(showsShadow ? 0.45 : 0), radius: 6, y: 3)
                .shadow(color: .black.opacity(showsShadow ? 0.4 : 0), radius: NotchMetrics.shadowRadius, y: 8)
                .animation(.easeInOut(duration: 0.35), value: showsShadow)
                .contentShape(shape.path(in: CGRect(x: 0, y: 0, width: width,
                                                    height: max(1, visibleHeight))))
                .onTapGesture(perform: onTap)
                .onDrop(of: [.fileURL], isTargeted: nil, perform: onDrop)
                .contextMenu(menuItems: contextMenu)
                // Margem da janela reservada para a sombra (a folga das orelhas
                // já está no conteúdo; a janela continua com `shadowMargin`).
                .padding(.horizontal, NotchMetrics.shadowMargin - flare)
                .padding(.bottom, NotchMetrics.shadowMargin)
                // A janela é menor que o conteúdo enquanto ele está recolhido:
                // sem isso o painel ficaria centralizado nela em vez de colar no topo.
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            content
        }
    }
}
