//  SessionHost.swift
//  Lado do anfitrião: anuncia a sala por Bonjour, aceita convidados, cuida de
//  quem está em cada controle e transmite vídeo e áudio para todos. Vive na
//  própria fila; o que interessa à UI sobe pelos callbacks.

import Foundation
import Network

final class SessionHost {
    private struct Guest {
        let id: UUID
        let connection: PeerConnection
        var name: String?
        var pingSentAt: UInt64?
        /// Já disse `hello`: aparece na sala.
        var joined: Bool { name != nil }
    }

    let code: String
    let hostId = UUID()
    private let queue = DispatchQueue(label: "com.ari.NotchSnes.online.host")
    private var listener: NWListener?
    private var guests: [UUID: Guest] = [:]
    private var room: RoomState
    private var pingTimer: DispatchSourceTimer?
    private let encoder: VideoEncoder?
    private var frameCounter: UInt32 = 0
    private var stopped = false

    // Callbacks na fila do anfitrião.
    var onRoomChange: ((RoomState) -> Void)?
    /// Entrada de um convidado no controle `slot` (1…3).
    var onInput: ((_ slot: Int, _ mask: UInt16) -> Void)?
    var onNotice: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    init(hostName: String, gameTitle: String) {
        code = SessionCode.generate()
        room = RoomState(code: code, hostName: hostName, gameTitle: gameTitle,
                         host: Participant(id: hostId, name: hostName, latencyMs: nil))
        encoder = VideoEncoder()
        encoder?.onEncoded = { [weak self] payload in
            self?.broadcast(WireMessage(type: .video, payload: payload))
        }
    }

    // MARK: - Ciclo de vida

    func start() {
        queue.async { [self] in
            do {
                let listener = try NWListener(using: PeerConnection.parameters())
                listener.service = NWListener.Service(
                    name: SessionCode.serviceName(for: code), type: SessionCode.serviceType,
                    txtRecord: NWTXTRecord(["code": code, "host": room.hostName, "v": "\(SessionCode.protocolVersion)"]))
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .failed(let error):
                        Log.online.error("listener falhou: \(error.localizedDescription, privacy: .public)")
                        onFailure?("Não deu para abrir a sessão na rede local")
                    case .ready:
                        Log.online.notice("sessão \(self.code, privacy: .public) anunciada na porta \(listener.port?.rawValue ?? 0)")
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
                self.listener = listener
                startPings()
            } catch {
                Log.online.error("NWListener: \(error.localizedDescription, privacy: .public)")
                onFailure?("Não deu para abrir a sessão na rede local")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            Log.online.notice("sessão \(self.code, privacy: .public) encerrada")
            pingTimer?.cancel()
            pingTimer = nil
            for guest in guests.values {
                guest.connection.send(.ended)
                // Dá tempo de o aviso sair antes de fechar.
                queue.asyncAfter(deadline: .now() + 0.3) { guest.connection.cancel() }
            }
            guests.removeAll()
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: - Ações do anfitrião

    func setLocked(_ locked: Bool) {
        queue.async { [self] in
            guard room.locked != locked else { return }
            room.locked = locked
            broadcastRoom()
        }
    }

    func remove(_ id: UUID) {
        queue.async { [self] in
            guard let guest = guests[id] else { return }
            guest.connection.send(.rejected("O anfitrião removeu você da sessão"))
            queue.asyncAfter(deadline: .now() + 0.3) { guest.connection.cancel() }
            drop(id, reason: nil)
        }
    }

    func setGameTitle(_ title: String) {
        queue.async { [self] in
            guard room.gameTitle != title else { return }
            room.gameTitle = title
            broadcastRoom()
        }
    }

    // MARK: - Mídia (thread da emulação)

    /// Framebuffer RGBA do PPU, uma vez por frame emulado.
    func sendFrame(rgba: UnsafeBufferPointer<UInt8>) {
        frameCounter &+= 1
        encoder?.encode(rgba: rgba, frame: frameCounter)
    }

    func sendAudio(left: [Int16], right: [Int16]) {
        broadcast(.audio(left: left, right: right))
    }

    private func broadcast(_ message: WireMessage) {
        queue.async { [self] in
            for guest in guests.values where guest.joined {
                guest.connection.send(message)
            }
        }
    }

    // MARK: - Convidados

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let peer = PeerConnection(connection: connection, queue: queue)
        guests[id] = Guest(id: id, connection: peer)
        peer.onMessage = { [weak self] message in self?.handle(message, from: id) }
        peer.onClose = { [weak self] _ in self?.drop(id, reason: "saiu") }
        peer.start()
        // Quem nunca se apresenta não fica pendurado na sala.
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, let guest = guests[id], !guest.joined else { return }
            guest.connection.cancel()
        }
    }

    private func handle(_ message: WireMessage, from id: UUID) {
        guard let guest = guests[id] else { return }
        switch message.type {
        case .control:
            guard let control = message.controlMessage() else { return }
            handle(control, from: id)
        case .input:
            guard guest.joined, let slot = room.slot(of: id) else { return }
            var reader = ByteReader(message.payload)
            guard let _ = reader.u8(), let mask = reader.u16() else { return }
            onInput?(slot, mask)
        case .ping:
            guest.connection.send(WireMessage(type: .pong, payload: message.payload))
        case .pong:
            var reader = ByteReader(message.payload)
            guard let sent = reader.u64(), guests[id]?.pingSentAt == sent else { return }
            let rtt = Int((DispatchTime.now().uptimeNanoseconds &- sent) / 1_000_000)
            guests[id]?.pingSentAt = nil
            update(id) { $0.latencyMs = rtt }
        case .video, .audio:
            break
        }
    }

    private func handle(_ control: ControlMessage, from id: UUID) {
        guard var guest = guests[id] else { return }
        switch control {
        case .hello(let name, let version):
            guard !guest.joined else { return }
            guard version == SessionCode.protocolVersion else {
                guest.connection.send(.rejected("Versão do NotchSnes diferente da do anfitrião"))
                queue.asyncAfter(deadline: .now() + 0.3) { guest.connection.cancel() }
                return
            }
            let cleanName = Self.clean(name)
            guest.name = cleanName
            guests[id] = guest
            let participant = Participant(id: id, name: cleanName, latencyMs: nil)
            room.spectators.append(participant)
            guest.connection.send(.welcome(id: id, room: room))
            encoder?.requestKeyframe()
            broadcastRoom()
            onNotice?("\(cleanName) entrou")

        case .takeSlot(let slot):
            guard guest.joined, (1..<RoomState.slotCount).contains(slot),
                  !room.locked, room.slots[slot] == nil,
                  let participant = room.participant(id) else { return }
            release(id)
            room.spectators.removeAll { $0.id == id }
            room.slots[slot] = participant
            broadcastRoom()
            onNotice?("\(participant.name) pegou o controle \(slot + 1)")

        case .releaseSlot:
            guard guest.joined, let participant = room.participant(id), room.slot(of: id) != nil else { return }
            release(id)
            room.spectators.append(participant)
            broadcastRoom()
            onNotice?("\(participant.name) soltou o controle")

        case .rename(let name):
            guard guest.joined else { return }
            let cleanName = Self.clean(name)
            guests[id]?.name = cleanName
            update(id) { $0.name = cleanName }

        case .welcome, .room, .notice, .rejected, .ended:
            break
        }
    }

    /// Tira do controle, zerando o pad para o jogo não ficar com botão preso.
    private func release(_ id: UUID) {
        guard let slot = room.slot(of: id) else { return }
        room.slots[slot] = nil
        onInput?(slot, 0)
    }

    private func drop(_ id: UUID, reason: String?) {
        guard let guest = guests.removeValue(forKey: id) else { return }
        guard guest.joined, let participant = room.participant(id) else { return }
        release(id)
        room.spectators.removeAll { $0.id == id }
        broadcastRoom()
        if let reason { onNotice?("\(participant.name) \(reason)") }
    }

    private func update(_ id: UUID, _ change: (inout Participant) -> Void) {
        if let slot = room.slot(of: id), var participant = room.slots[slot] {
            change(&participant)
            room.slots[slot] = participant
        } else if let index = room.spectators.firstIndex(where: { $0.id == id }) {
            change(&room.spectators[index])
        } else {
            return
        }
        broadcastRoom()
    }

    private func broadcastRoom() {
        let message = ControlMessage.room(room)
        for guest in guests.values where guest.joined {
            guest.connection.send(message)
        }
        onRoomChange?(room)
    }

    private static func clean(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Convidado" : String(trimmed.prefix(16))
    }

    // MARK: - Latência

    private func startPings() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            for id in guests.keys where guests[id]?.joined == true {
                guests[id]?.pingSentAt = now
                guests[id]?.connection.send(.ping(nanos: now))
            }
        }
        timer.resume()
        pingTimer = timer
    }
}
