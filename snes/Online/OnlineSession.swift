//  OnlineSession.swift
//  Estado da sessão online como a UI o vê, no main actor: se somos anfitrião
//  ou convidado, quem está na sala, latência, avisos. Faz a ponte entre o
//  emulador (frames, áudio, controles) e o `SessionHost`/`SessionGuest`.

import AppKit
import Combine

@MainActor
final class OnlineSession: ObservableObject {
    enum Mode: Equatable {
        case idle
        case hosting
        /// Procurando/conectando ao anfitrião do código.
        case joining(String)
        case guest
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var room: RoomState?
    /// Nosso id na sala (o do anfitrião quando somos ele).
    @Published private(set) var myId: UUID?
    /// Ida e volta até o anfitrião, só no convidado.
    @Published private(set) var latencyMs: Int?
    /// Aviso passageiro ("Bia pegou o controle 3"); some sozinho.
    @Published private(set) var notice: String?
    /// Erro ou motivo do fim da última sessão; fica até a próxima ação.
    @Published private(set) var error: String?
    /// Código sendo digitado para entrar.
    @Published var joinCode = ""

    /// Frames do anfitrião, quando somos convidado. Fora do `@Published`
    /// de propósito, como o `FrameSource` do emulador.
    let guestFrames = FrameSource()

    /// Entrada de um convidado para o console local (anfitrião).
    var onGuestInput: ((_ slot: Int, _ mask: UInt16) -> Void)?

    private var host: SessionHost?
    private var guest: SessionGuest?
    private var noticeWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    var isHosting: Bool { mode == .hosting }
    var isGuest: Bool { mode == .guest }
    var isJoining: Bool { if case .joining = mode { return true } else { return false } }
    var isActive: Bool { mode != .idle }

    var mySlot: Int? {
        guard let room, let myId else { return nil }
        return room.slot(of: myId)
    }

    init() {
        NotchSettings.shared.$volume.combineLatest(NotchSettings.shared.$muted)
            .sink { [weak self] volume, muted in
                self?.guest?.audio.volume = muted ? 0 : Float(volume)
            }
            .store(in: &cancellables)
        NotchSettings.shared.$playerName
            .dropFirst()
            .sink { [weak self] name in self?.guest?.rename(name) }
            .store(in: &cancellables)
    }

    // MARK: - Anfitrião

    func startHosting(gameTitle: String) {
        guard mode == .idle else { return }
        error = nil
        let host = SessionHost(hostName: NotchSettings.shared.playerName, gameTitle: gameTitle)
        host.onRoomChange = { [weak self] room in
            Self.onMain { self?.room = room }
        }
        host.onInput = { [weak self] slot, mask in
            Self.onMain { self?.onGuestInput?(slot, mask) }
        }
        host.onNotice = { [weak self] text in
            Self.onMain { self?.show(notice: text) }
        }
        host.onFailure = { [weak self] text in
            Self.onMain {
                self?.stopHosting()
                self?.error = text
            }
        }
        self.host = host
        myId = host.hostId
        room = RoomState(code: host.code, hostName: NotchSettings.shared.playerName, gameTitle: gameTitle,
                         host: Participant(id: host.hostId, name: NotchSettings.shared.playerName, latencyMs: nil))
        mode = .hosting
        host.start()
    }

    func stopHosting() {
        guard let host else { return }
        host.stop()
        self.host = nil
        // Solta os controles remotos: nada pode ficar pressionado no console.
        for slot in 1..<RoomState.slotCount { onGuestInput?(slot, 0) }
        clear()
    }

    func setLocked(_ locked: Bool) { host?.setLocked(locked) }
    func remove(_ id: UUID) { host?.remove(id) }
    func gameTitleChanged(_ title: String) { host?.setGameTitle(title) }

    /// Chamado a cada frame emulado, com o framebuffer RGBA do PPU.
    func hostDidRunFrame(rgba: UnsafeBufferPointer<UInt8>) {
        host?.sendFrame(rgba: rgba)
    }

    /// Chamado pelo tap de áudio do APU, junto com cada frame emulado.
    func hostDidProduceAudio(left: [Int16], right: [Int16]) {
        host?.sendAudio(left: left, right: right)
    }

    // MARK: - Convidado

    func join(code rawCode: String) {
        guard mode == .idle else { return }
        let code = SessionCode.normalize(rawCode)
        guard SessionCode.isComplete(code) else {
            error = "O código tem 6 letras e números"
            return
        }
        error = nil
        let guest = SessionGuest(code: code, name: NotchSettings.shared.playerName)
        guest.onPhase = { [weak self] phase in
            Self.onMain { self?.guestPhaseChanged(phase) }
        }
        guest.onWelcome = { [weak self] id, room in
            Self.onMain {
                self?.myId = id
                self?.room = room
            }
        }
        guest.onRoom = { [weak self] room in
            Self.onMain { self?.room = room }
        }
        guest.onNotice = { [weak self] text in
            Self.onMain { self?.show(notice: text) }
        }
        guest.onFrame = { [weak self] image in
            Self.onMain { self?.guestFrames.publish(image) }
        }
        guest.onLatency = { [weak self] ms in
            Self.onMain { self?.latencyMs = ms }
        }
        guest.audio.volume = NotchSettings.shared.effectiveVolume
        self.guest = guest
        mode = .joining(code)
        guest.start()
    }

    func leave() {
        guard let guest else { return }
        guest.stop()
        self.guest = nil
        clear()
    }

    func takeSlot(_ slot: Int) { guest?.takeSlot(slot) }
    func releaseSlot() { guest?.releaseSlot() }

    /// Máscara do controle local, quando somos convidado.
    func sendInput(_ mask: UInt16) { guest?.sendInput(mask) }

    private func guestPhaseChanged(_ phase: SessionGuest.Phase) {
        switch phase {
        case .searching, .connecting:
            break
        case .connected:
            mode = .guest
        case .ended(let reason):
            guest = nil
            clear()
            if !reason.isEmpty { error = reason }
        }
    }

    // MARK: - Comum

    func dismissError() { error = nil }

    private func clear() {
        mode = .idle
        room = nil
        myId = nil
        latencyMs = nil
        notice = nil
        noticeWork?.cancel()
    }

    private func show(notice text: String) {
        noticeWork?.cancel()
        notice = text
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.notice = nil }
        }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}
