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

/// Overlay em pixels do framebuffer (256×224), composto no frame antes dos
/// filtros retro: assim curvatura, scanlines e fósforo também o afetam.
struct FrameOverlay: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    /// Fade global aplicado na composição.
    let alpha: Float
    /// RGBA pré-multiplicado, `width * height * 4` bytes.
    let pixels: [UInt8]

    static let frameWidth = 256
    static let frameHeight = 224

    /// Mescla o overlay sobre `frame` (RGBA, `rowBytes` por linha).
    func blend(into frame: inout [UInt8], rowBytes: Int) {
        let fade = max(0, min(1, alpha))
        guard fade > 0 else { return }
        for row in 0..<height {
            let fy = y + row
            guard fy >= 0, fy < Self.frameHeight else { continue }
            for col in 0..<width {
                let fx = x + col
                guard fx >= 0, fx < Self.frameWidth else { continue }
                let s = (row * width + col) * 4
                let srcA = Float(pixels[s + 3]) * fade
                guard srcA > 0 else { continue }
                let d = fy * rowBytes + fx * 4
                let inv = 1 - srcA / 255
                frame[d]     = UInt8(min(255, Float(pixels[s])     * fade + Float(frame[d])     * inv))
                frame[d + 1] = UInt8(min(255, Float(pixels[s + 1]) * fade + Float(frame[d + 1]) * inv))
                frame[d + 2] = UInt8(min(255, Float(pixels[s + 2]) * fade + Float(frame[d + 2]) * inv))
            }
        }
    }

    /// Para o caminho reserva sem Metal (sublayer por cima do frame).
    func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}

struct ScreenView: NSViewRepresentable {
    let source: FrameSource
    var filter: ScreenFilter = .clean
    var osd: FrameOverlay? = nil

    func makeNSView(context: Context) -> NSView {
        if let metal = MetalFrameView.make() {
            metal.bind(to: source)
            metal.filter = filter
            metal.overlay = osd
            return metal
        }
        let view = FrameLayerView()
        view.bind(to: source)
        view.overlay = osd
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let metal = nsView as? MetalFrameView {
            metal.bind(to: source)
            metal.filter = filter
            metal.overlay = osd
        } else if let view = nsView as? FrameLayerView {
            view.bind(to: source)
            view.overlay = osd
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
    private var latestImage: CGImage?
    /// Reaproveitado na composição frame + overlay para não alocar a 60 Hz.
    private var scratch = [UInt8](repeating: 0, count: 256 * 224 * 4)

    var filter: ScreenFilter = .clean {
        didSet { if filter != oldValue { needsDisplay = true } }
    }

    /// OSD composto na textura de 256×224; o shader trata como parte do frame.
    var overlay: FrameOverlay? {
        didSet {
            guard overlay != oldValue else { return }
            if let latestImage { upload(latestImage) }
        }
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
        latestImage = image
        guard image.width == 256, image.height == 224,
              image.bitsPerPixel == 32,
              let data = image.dataProvider?.data,
              CFDataGetLength(data) >= image.bytesPerRow * image.height,
              let bytes = CFDataGetBytePtr(data) else { return }
        if let overlay, overlay.alpha > 0 {
            let srcRowBytes = image.bytesPerRow
            let dstRowBytes = 256 * 4
            scratch.withUnsafeMutableBytes { dst in
                let base = dst.baseAddress!
                for row in 0..<224 {
                    memcpy(base + row * dstRowBytes, bytes + row * srcRowBytes, dstRowBytes)
                }
            }
            overlay.blend(into: &scratch, rowBytes: dstRowBytes)
            frameTexture.replace(region: MTLRegionMake2D(0, 0, 256, 224),
                                 mipmapLevel: 0,
                                 withBytes: scratch,
                                 bytesPerRow: dstRowBytes)
        } else {
            frameTexture.replace(region: MTLRegionMake2D(0, 0, 256, 224),
                                 mipmapLevel: 0,
                                 withBytes: bytes,
                                 bytesPerRow: image.bytesPerRow)
        }
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
    private let osdLayer = CALayer()

    /// Sem Metal não há filtro para acompanhar; o OSD vira sublayer escalada
    /// junto com o frame.
    var overlay: FrameOverlay? {
        didSet {
            guard overlay != oldValue else { return }
            if let overlay, overlay.alpha > 0, let image = overlay.cgImage() {
                osdLayer.contents = image
                osdLayer.opacity = overlay.alpha
                osdLayer.isHidden = false
            } else {
                osdLayer.isHidden = true
            }
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest   // pixel perfect
        layer?.minificationFilter = .nearest
        osdLayer.contentsGravity = .resize
        osdLayer.magnificationFilter = .nearest
        osdLayer.isHidden = true
        osdLayer.actions = ["contents": NSNull(), "opacity": NSNull(),
                            "hidden": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(osdLayer)
    }

    override func layout() {
        super.layout()
        guard let overlay else { return }
        let sx = bounds.width / CGFloat(FrameOverlay.frameWidth)
        let sy = bounds.height / CGFloat(FrameOverlay.frameHeight)
        osdLayer.frame = CGRect(x: CGFloat(overlay.x) * sx,
                                y: CGFloat(overlay.y) * sy,
                                width: CGFloat(overlay.width) * sx,
                                height: CGFloat(overlay.height) * sy)
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
