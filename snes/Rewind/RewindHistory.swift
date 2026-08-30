//  RewindHistory.swift
//  Últimos segundos de jogo: um snapshot do console a cada `interval` frames,
//  comprimido com LZ4 num ring buffer, com o frame renderizado ao lado para a
//  fita de miniaturas.

import Compression
import CoreGraphics
import Foundation

final class RewindHistory {
    struct Entry {
        let state: CompressedState
        let image: CGImage?
        /// Ordinal crescente desde o início do histórico; sobrevive à rotação do ring.
        let serial: Int
    }

    /// Frames entre snapshots. 6 ≈ 100 ms a 60 Hz.
    static let interval = 6
    /// Snapshots guardados. 100 × 100 ms = 10 s.
    static let capacity = 100

    private(set) var entries: [Entry] = []
    private var frameCounter = 0
    private var nextSerial = 0

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    /// Segundos entre dois índices do histórico.
    static func seconds(from a: Int, to b: Int) -> Double {
        Double(b - a) * Double(interval) / 60.0988
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
        frameCounter = 0
    }

    /// Chamado a cada frame emulado; captura quando chega a hora.
    func frameDidRun(capture: () -> (state: [UInt8], image: CGImage?)) {
        frameCounter += 1
        guard frameCounter >= Self.interval else { return }
        frameCounter = 0
        let (state, image) = capture()
        append(state: state, image: image)
    }

    /// Captura fora do ritmo (ao entrar no modo de voltar), sem mexer no contador.
    func append(state: [UInt8], image: CGImage?) {
        entries.append(Entry(state: CompressedState(state), image: image, serial: nextSerial))
        nextSerial += 1
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    /// Descarta tudo depois de `index`: o jogador voltou para lá e o futuro deixou de existir.
    func truncate(after index: Int) {
        guard index + 1 < entries.count else { return }
        entries.removeSubrange((index + 1)...)
        frameCounter = 0
    }
}

/// Bytes de um state comprimidos com LZ4 (rápido o bastante para rodar a cada 100 ms).
struct CompressedState {
    let bytes: [UInt8]
    let originalCount: Int

    init(_ raw: [UInt8]) {
        originalCount = raw.count
        var dst = [UInt8](repeating: 0, count: raw.count + 64)
        let n = raw.withUnsafeBufferPointer { src in
            dst.withUnsafeMutableBufferPointer { out in
                compression_encode_buffer(out.baseAddress!, out.count,
                                          src.baseAddress!, src.count,
                                          nil, COMPRESSION_LZ4)
            }
        }
        if n > 0 {
            dst.removeSubrange(n...)
            bytes = dst
        } else {
            // LZ4 não coube (dados incompressíveis): guarda cru, marcado pelo tamanho igual.
            bytes = raw
        }
    }

    func decompressed() -> [UInt8] {
        guard bytes.count != originalCount else { return bytes }
        var out = [UInt8](repeating: 0, count: originalCount)
        let n = bytes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, dst.count,
                                          src.baseAddress!, src.count,
                                          nil, COMPRESSION_LZ4)
            }
        }
        return n == originalCount ? out : []
    }
}
