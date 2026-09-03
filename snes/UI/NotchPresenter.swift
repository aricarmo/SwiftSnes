//  NotchPresenter.swift
//  Máquina de estados do painel: colapsado, hover, fixado e ajustes.

import AppKit
import Combine

@MainActor
final class NotchPresenter: ObservableObject {
    private let settings: NotchSettings

    init(settings: NotchSettings) {
        self.settings = settings
    }

    /// Cursor dentro da região quente (já com os atrasos aplicados). Só mostra
    /// o cabeçalho (título e estado); expandir exige clique.
    @Published private(set) var isHovering = false
    /// Expandido por clique. Recolhe quando o cursor sai.
    @Published private(set) var isExpanded = false
    /// Fixado: o painel não recolhe e o teclado fica capturado.
    @Published var isPinned = false
    /// Subpainel de ajustes aberto.
    @Published var showsSettings = false
    /// Regravando uma tecla: o jogo ignora o teclado enquanto isso.
    @Published var rebindingButton: SNESButton?
    /// Regravando um botão do controle: o próximo botão físico pressionado vira o mapeamento.
    @Published var rebindingPadButton: SNESButton?
    /// Há um controle conectado: o jogo pode rodar sem capturar o teclado.
    @Published var hasGamepad = false
    /// Sem ROM o painel fica sempre aberto.
    @Published var hasROM = false
    /// Transmitindo para convidados: o jogo não pode parar quando o painel recolhe.
    @Published var isHosting = false
    /// App ativo (painel com foco). Atualizado pelo controller via notificações.
    @Published var isAppActive = false
    /// Cursor sobre o painel, sem atraso: a sombra reage antes de o painel abrir.
    @Published private(set) var cursorInside = false

    /// Sombra em volta do painel: aparece com o cursor sobre ele ou com foco;
    /// some quando o app perde o foco e o cursor sai.
    var showsShadow: Bool { cursorInside || isHovering || isAppActive }

    /// Atrasos do design: 350 ms para abrir, 400 ms de tolerância para fechar.
    static let openDelay: TimeInterval = 0.35
    static let closeDelay: TimeInterval = 0.40

    var isOpen: Bool { isExpanded || isPinned || showsSettings || !hasROM }
    /// Cabeçalho visível: aberto ou só espiando com o cursor em cima.
    var showsHeader: Bool { isOpen || isHovering }
    /// Teclado capturado: fixado, nos ajustes, ou simplesmente com o cursor sobre
    /// o painel de um jogo carregado — hover sozinho já vale, senão o jogo roda
    /// sem responder às teclas.
    var needsKeyboard: Bool {
        if showsSettings || rebindingButton != nil { return true }
        // Com controle, jogar fixado não rouba o teclado de outro app.
        if hasGamepad && isPinned && !isExpanded { return false }
        return isPinned || (isExpanded && hasROM)
    }
    /// O jogo só roda com o painel aberto (ou se a pausa automática estiver desligada).
    var shouldRun: Bool { hasROM && (isOpen || isHosting || !settings.pauseOnHide) }

    private var hoverWorkItem: DispatchWorkItem?
    /// Último lado informado pelo monitor, antes do atraso.
    private var pendingHover = false

    /// Chamado pelo monitor de mouse a cada movimento.
    func cursorInsideChanged(_ inside: Bool) {
        guard inside != pendingHover else { return }
        pendingHover = inside
        cursorInside = inside
        hoverWorkItem?.cancel()
        guard inside != isHovering else { return }

        let delay = inside ? Self.openDelay : Self.closeDelay
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isHovering = inside
                if !inside { self.isExpanded = false }
            }
        }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Clique na pílula: expande na hora, sem esperar o atraso de hover.
    func openImmediately() {
        hoverWorkItem?.cancel()
        pendingHover = true
        cursorInside = true
        isHovering = true
        isExpanded = true
    }

    func closeImmediately() {
        hoverWorkItem?.cancel()
        pendingHover = false
        cursorInside = false
        isHovering = false
        isExpanded = false
        showsSettings = false
        rebindingButton = nil
        rebindingPadButton = nil
    }

    func togglePin() {
        isPinned.toggle()
        if isPinned { openImmediately() }
    }
}

/// Observa a posição do cursor sem depender de tracking area em janela inativa.
///
/// Monitores de evento dão a resposta imediata; o timer cobre os casos em que
/// nenhum evento chega (cursor movido por software, app em tela cheia na frente,
/// warp do sistema). Ler `NSEvent.mouseLocation` é barato.
@MainActor
final class NotchHoverMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pollTimer: Timer?
    private let onMove: (NSPoint) -> Void

    static let pollInterval: TimeInterval = 0.1

    init(onMove: @escaping (NSPoint) -> Void) {
        self.onMove = onMove
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMove(NSEvent.mouseLocation) }
        }
        // O monitor global não vê eventos do próprio app quando ele está ativo.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.onMove(NSEvent.mouseLocation)
            return event
        }

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMove(NSEvent.mouseLocation) }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func invalidate() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
