//  ScreenView.swift
//  Tela do jogo. Os frames chegam por `FrameSource` direto na view, sem
//  passar pelo SwiftUI: a 60 Hz uma `@Published` invalidaria o painel inteiro.
//  O desenho é um MTKView com os filtros retro do RetroShaders.metal; se o
//  Metal não estiver disponível, cai no CALayer puro de antes.

import AppKit
import Combine
import MetalKit
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
    var filter: ScreenFilter = .clean

    func makeNSView(context: Context) -> NSView {
        if let metal = MetalFrameView.make() {
            metal.bind(to: source)
            metal.filter = filter
            return metal
        }
        let view = FrameLayerView()
        view.bind(to: source)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let metal = nsView as? MetalFrameView {
            metal.bind(to: source)
            metal.filter = filter
        } else if let view = nsView as? FrameLayerView {
            view.bind(to: source)
        }
    }
}

// MARK: - Caminho Metal

/// Desenha o frame com os filtros retro. Pausado: só redesenha quando chega
/// frame novo ou o filtro muda, igual ao comportamento do CALayer.
final class MetalFrameView: MTKView, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let frameTexture: MTLTexture

    private var subscription: AnyCancellable?
    private weak var boundSource: FrameSource?

    var filter: ScreenFilter = .clean {
        didSet { if filter != oldValue { needsDisplay = true } }
    }

    /// `MTKView.init()` não pode virar falível; a montagem que pode falhar
    /// (device, shaders, textura) fica nesta fábrica.
    static func make() -> MetalFrameView? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunc = library.makeFunction(name: "screenVertex"),
              let fragFunc = library.makeFunction(name: "screenFragment") else {
            return nil
        }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFunc
        pipelineDesc.fragmentFunction = fragFunc
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pipelineDesc) else {
            return nil
        }

        let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 256, height: 224, mipmapped: false)
        textureDesc.usage = [.shaderRead]
        if device.hasUnifiedMemory { textureDesc.storageMode = .shared }
        guard let texture = device.makeTexture(descriptor: textureDesc) else {
            return nil
        }

        return MetalFrameView(device: device, queue: queue, pipeline: pipeline, texture: texture)
    }

    private init(device: MTLDevice, queue: MTLCommandQueue,
                 pipeline: MTLRenderPipelineState, texture: MTLTexture) {
        self.commandQueue = queue
        self.pipeline = pipeline
        self.frameTexture = texture
        super.init(frame: .zero, device: device)

        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    @MainActor
    func bind(to source: FrameSource) {
        guard boundSource !== source else { return }
        boundSource = source
        if let latest = source.latest { upload(latest) }
        subscription = source.frames.sink { [weak self] image in
            self?.upload(image)
        }
    }

    /// O CGImage do PPU embrulha o framebuffer RGBA cru; os bytes vão direto
    /// para a textura, sem redesenho por CoreGraphics.
    private func upload(_ image: CGImage) {
        guard image.width == 256, image.height == 224,
              image.bitsPerPixel == 32,
              let data = image.dataProvider?.data,
              CFDataGetLength(data) >= image.bytesPerRow * image.height,
              let bytes = CFDataGetBytePtr(data) else { return }
        frameTexture.replace(region: MTLRegionMake2D(0, 0, 256, 224),
                             mipmapLevel: 0,
                             withBytes: bytes,
                             bytesPerRow: image.bytesPerRow)
        needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let rpd = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }

        var uniforms = DisplayUniforms.preset(
            for: filter,
            drawableSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
        encoder.setFragmentTexture(frameTexture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - Reserva sem Metal

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
