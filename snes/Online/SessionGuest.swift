//  SessionGuest.swift
//  Lado do convidado: acha o anfitrião pelo código na rede local, conecta,
//  decodifica vídeo e áudio e manda a máscara do controle. Vive na própria
//  fila; o que interessa à UI sobe pelos callbacks.

import CoreGraphics
import Foundation
import Network

final class SessionGuest {
    enum Phase: Equatable {
        case searching
        case connecting
        case connected
        case ended(String)
    }

    let code: String
    private let name: String
    private let queue = DispatchQueue(label: "com.ari.NotchSnes.online.guest")
    private var browser: NWBrowser?
    private var connection: PeerConnection?
    private var decoder = VideoDecoder()
    let audio = AudioOutput()
    private var pingTimer: DispatchSourceTimer?
    private var pingSentAt: UInt64?
    private var searchTimeout: DispatchWorkItem?
    private var lastMask: UInt16 = 0
    private var finished = false

    // Callbacks na fila do convidado.
    var onPhase: ((Phase) -> Void)?
    var onWelcome: ((_ id: UUID, _ room: RoomState) -> Void)?
    var onRoom: ((RoomState) -> Void)?
    var onNotice: ((String) -> Void)?
    var onFrame: ((CGImage) -> Void)?
    var onLatency: ((Int) -> Void)?

    init(code: String, name: String) {
        self.code = code
        self.name = name
        decoder.onFrame = { [weak self] image in self?.onFrame?(image) }
    }

    // MARK: - Ciclo de vida

    func start() {
        queue.async { [self] in
            onPhase?(.searching)
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: SessionCode.serviceType, domain: nil),
                                    using: PeerConnection.parameters())
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    Log.online.error("browser falhou: \(error.localizedDescription, privacy: .public)")
                    self?.finish("Não deu para procurar sessões na rede local")
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.match(results)
            }
            browser.start(queue: queue)
            self.browser = browser

            let timeout = DispatchWorkItem { [weak self] in
                guard let self, connection == nil else { return }
                finish("Nenhuma sessão \(SessionCode.display(code)) na rede local")
            }
            searchTimeout = timeout
            queue.asyncAfter(deadline: .now() + 12, execute: timeout)
        }
    }

    func stop() {
        queue.async { [self] in finish(nil) }
    }

    // MARK: - Ações

    func takeSlot(_ slot: Int) { send(.takeSlot(slot)) }
    func releaseSlot() { send(.releaseSlot) }
    func rename(_ name: String) { send(.rename(name)) }

    /// Máscara do controle local; só viaja quando muda.
    func sendInput(_ mask: UInt16) {
        queue.async { [self] in
            guard mask != lastMask else { return }
            lastMask = mask
            connection?.send(.input(slot: 0, mask: mask))
        }
    }

    private func send(_ control: ControlMessage) {
        queue.async { [self] in connection?.send(control) }
    }

    // MARK: - Descoberta e conexão

    private func match(_ results: Set<NWBrowser.Result>) {
        guard connection == nil else { return }
        for result in results {
            var matches = false
            if case .bonjour(let txt) = result.metadata, txt["code"] == code { matches = true }
            if case .service(let serviceName, _, _, _) = result.endpoint,
               serviceName == SessionCode.serviceName(for: code) { matches = true }
            guard matches else { continue }
            connect(to: result.endpoint)
            return
        }
    }

    private func connect(to endpoint: NWEndpoint) {
        searchTimeout?.cancel()
        browser?.cancel()
        browser = nil
        onPhase?(.connecting)

        let peer = PeerConnection(connection: NWConnection(to: endpoint, using: PeerConnection.parameters()),
                                  queue: queue)
        peer.onReady = { [weak self] in
            guard let self else { return }
            peer.send(.hello(name: name, version: SessionCode.protocolVersion))
        }
        peer.onMessage = { [weak self] message in self?.handle(message) }
        peer.onClose = { [weak self] error in
            guard let self else { return }
            finish(error == nil ? "A sessão terminou" : "Conexão com o anfitrião perdida")
        }
        connection = peer
        peer.start()
    }

    private func handle(_ message: WireMessage) {
        switch message.type {
        case .video:
            decoder.decode(message.payload)
        case .audio:
            var reader = ByteReader(message.payload)
            guard let count = reader.u16() else { return }
            let samples = reader.rest()
            guard samples.count >= Int(count) * 4 else { return }
            var left = [Int16](repeating: 0, count: Int(count))
            var right = [Int16](repeating: 0, count: Int(count))
            samples.withUnsafeBytes { raw in
                for i in 0..<Int(count) {
                    left[i] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: Int16.self))
                    right[i] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self))
                }
            }
            audio.writeSamples(left: left, right: right)
        case .control:
            guard let control = message.controlMessage() else { return }
            switch control {
            case .welcome(let id, let room):
                audio.start()
                startPings()
                onPhase?(.connected)
                onWelcome?(id, room)
            case .room(let room):
                onRoom?(room)
            case .notice(let text):
                onNotice?(text)
            case .rejected(let reason):
                finish(reason)
            case .ended:
                finish("O anfitrião encerrou a sessão")
            case .hello, .takeSlot, .releaseSlot, .rename:
                break
            }
        case .ping:
            connection?.send(WireMessage(type: .pong, payload: message.payload))
        case .pong:
            var reader = ByteReader(message.payload)
            guard let sent = reader.u64(), sent == pingSentAt else { return }
            pingSentAt = nil
            onLatency?(Int((DispatchTime.now().uptimeNanoseconds &- sent) / 1_000_000))
        case .input:
            break
        }
    }

    private func startPings() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            pingSentAt = now
            connection?.send(.ping(nanos: now))
        }
        timer.resume()
        pingTimer = timer
    }

    /// Encerra tudo; `reason` nulo é saída voluntária.
    private func finish(_ reason: String?) {
        guard !finished else { return }
        finished = true
        searchTimeout?.cancel()
        pingTimer?.cancel()
        pingTimer = nil
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        audio.stop()
        onPhase?(.ended(reason ?? ""))
    }
}
