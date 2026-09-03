//  PeerConnection.swift
//  Uma conexão TCP com o outro lado da sessão, já falando em `WireMessage`:
//  enquadra o que sai e remonta o que chega. Tudo numa fila própria.

import Foundation
import Network

final class PeerConnection {
    let connection: NWConnection
    let queue: DispatchQueue
    /// Chamado na fila da conexão.
    var onMessage: ((WireMessage) -> Void)?
    var onReady: (() -> Void)?
    /// Fechou ou falhou; `nil` é fechamento limpo.
    var onClose: ((NWError?) -> Void)?

    private var closed = false

    /// Parâmetros da sessão: TCP sem Nagle (os pacotes de entrada são de 3
    /// bytes e não podem esperar), com peer-to-peer para Macs sem roteador.
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                onReady?()
                receiveHeader()
            case .failed(let error):
                finish(error)
            case .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ message: WireMessage) {
        guard !closed else { return }
        connection.send(content: message.encoded(), completion: .contentProcessed { _ in })
    }

    func send(_ control: ControlMessage) {
        guard let message = WireMessage.control(control) else { return }
        send(message)
    }

    func cancel() {
        guard !closed else { return }
        connection.cancel()
    }

    private func finish(_ error: NWError?) {
        guard !closed else { return }
        closed = true
        onClose?(error)
    }

    // MARK: - Recepção

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: WireMessage.headerSize,
                           maximumLength: WireMessage.headerSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, data.count == WireMessage.headerSize, error == nil else {
                if isComplete || error != nil { connection.cancel() }
                return
            }
            var reader = ByteReader(data)
            guard let raw = reader.u8(), let type = WireType(rawValue: raw),
                  let length = reader.u32(), Int(length) <= WireMessage.maxPayload else {
                connection.cancel()
                return
            }
            if length == 0 {
                onMessage?(WireMessage(type: type, payload: Data()))
                receiveHeader()
                return
            }
            receivePayload(type: type, length: Int(length))
        }
    }

    private func receivePayload(type: WireType, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, data.count == length, error == nil else {
                connection.cancel()
                return
            }
            onMessage?(WireMessage(type: type, payload: data))
            receiveHeader()
        }
    }
}
