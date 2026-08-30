//  ScreenView.swift
//  Tela do jogo. Os frames chegam por `FrameSource` direto no CALayer, sem
//  passar pelo SwiftUI: a 60 Hz uma `@Published` invalidaria o painel inteiro.

import AppKit
import Combine
import SwiftUI

/// Canal de frames entre o emulador e a tela. Não é observado pelo SwiftUI.
@MainActor
final class FrameSource {
    private let subject = PassthroughSubject<CGImage, Never>()

    var frames: AnyPublisher<CGImage, Never> { subject.eraseToAnyPublisher() }
    private(set) var latest: CGImage?

    func publish(_ image: CGImage) {
        latest = image
        subject.send(image)
    }
}

struct ScreenView: NSViewRepresentable {
    let source: FrameSource

    func makeNSView(context: Context) -> FrameLayerView {
        let view = FrameLayerView()
        view.bind(to: source)
        return view
    }

    func updateNSView(_ nsView: FrameLayerView, context: Context) {
        nsView.bind(to: source)
    }
}

final class FrameLayerView: NSView {
    private var subscription: AnyCancellable?
    private weak var boundSource: FrameSource?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest   // pixel perfect
        layer?.minificationFilter = .nearest
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var isFlipped: Bool { true }

    @MainActor
    func bind(to source: FrameSource) {
        guard boundSource !== source else { return }
        boundSource = source
        if let latest = source.latest { layer?.contents = latest }
        subscription = source.frames.sink { [weak self] image in
            self?.layer?.contents = image
        }
    }
}
