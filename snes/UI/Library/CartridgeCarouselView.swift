//  CartridgeCarouselView.swift
//  Carrossel 3D dos cartuchos: SCNView transparente no corpo do painel. O
//  cartucho escolhido fica de frente no centro; os vizinhos, girados e menores
//  dos lados. Trocar a seleção anima posição, escala e giro de cada nó.

import AppKit
import SceneKit
import SwiftUI

struct CartridgeCarouselView: NSViewRepresentable {
    let entries: [GameLibrary.Item]
    let selectedIndex: Int
    /// Cartucho em animação de encaixe, se houver.
    let insertingId: String?
    /// Inclinação do cartucho escolhido (stick direito), -1...1.
    let tilt: CGPoint
    /// Muda quando alguma capa chega: força reavaliar as etiquetas.
    let coverVersion: Int
    let cover: (GameLibrary.Item) -> NSImage?
    let onPick: (Int) -> Void
    let onStep: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CarouselSCNView {
        let view = CarouselSCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.cameraNode
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.isJitteringEnabled = false
        view.onPick = { node in
            guard let index = context.coordinator.index(of: node) else { return }
            onPick(index)
        }
        view.onStep = onStep
        context.coordinator.apply(entries: entries, selected: selectedIndex, insertingId: insertingId, tilt: tilt, cover: cover, animated: false)
        return view
    }

    func updateNSView(_ view: CarouselSCNView, context: Context) {
        view.onPick = { node in
            guard let index = context.coordinator.index(of: node) else { return }
            onPick(index)
        }
        view.onStep = onStep
        context.coordinator.apply(entries: entries, selected: selectedIndex, insertingId: insertingId, tilt: tilt, cover: cover, animated: true)
    }

    @MainActor
    final class Coordinator {
        let scene = SCNScene()
        let cameraNode = SCNNode()
        private var nodes: [String: CartridgeNode] = [:]
        private var hasCover: [String: Bool] = [:]
        private var order: [String] = []
        private var insertingId: String?
        private var tilt = CGPoint.zero
        private var lastSelected = -1

        // A view vai até o rodapé, por baixo do nome e dos pontos, para o
        // cartucho encaixado não parar no meio de uma faixa preta. A câmera
        // compensa: o carrossel fica onde ficaria numa view só da altura dele.
        private static let cameraZ: CGFloat = 24
        private static let frontZ: CGFloat = 3
        /// Campo de visão vertical que o carrossel teria sozinho.
        private static let baseFOV: CGFloat = 30 * .pi / 180
        private static var fieldOfView: CGFloat {
            let ratio = (NotchMetrics.libraryCarouselHeight + NotchMetrics.librarySlotHeight) / NotchMetrics.libraryCarouselHeight
            return 2 * atan(tan(baseFOV / 2) * ratio)
        }
        /// Desce a câmera o equivalente à metade da área extra, medido no plano do cartucho da frente.
        private static var cameraY: CGFloat {
            let unitsPerPoint = (cameraZ - frontZ) * tan(baseFOV / 2) / (NotchMetrics.libraryCarouselHeight / 2)
            return 0.5 - NotchMetrics.librarySlotHeight / 2 * unitsPerPoint
        }
        /// Altura em que o cartucho encaixado para: só 2 cm dele acima da borda de baixo da view.
        static var slotY: CGFloat {
            let bottom = cameraY - (cameraZ - 7) * tan(fieldOfView / 2)
            return bottom + 2 - CartridgeModel.height / 2 * 1.08
        }

        init() {
            scene.background.contents = nil
            let camera = SCNCamera()
            camera.projectionDirection = .vertical
            camera.fieldOfView = Self.fieldOfView * 180 / .pi
            camera.wantsHDR = false
            camera.zNear = 1
            camera.zFar = 200
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, Self.cameraY, Self.cameraZ)
            scene.rootNode.addChildNode(cameraNode)

            addLight(.directional, intensity: 1000, at: SCNVector3(-8, 16, 20), color: .white, shadows: true)
            addLight(.omni, intensity: 450, at: SCNVector3(14, 4, 18),
                     color: NSColor(calibratedRed: 0.72, green: 0.61, blue: 1, alpha: 1), shadows: false)
            addLight(.ambient, intensity: 200, at: SCNVector3(0, 0, 0), color: NSColor(white: 0.8, alpha: 1), shadows: false)
        }

        private func addLight(_ type: SCNLight.LightType, intensity: CGFloat, at position: SCNVector3,
                              color: NSColor, shadows: Bool) {
            let light = SCNLight()
            light.type = type
            light.intensity = intensity
            light.color = color
            light.castsShadow = shadows
            if shadows {
                light.shadowMode = .deferred
                light.shadowRadius = 6
                light.shadowColor = NSColor.black.withAlphaComponent(0.5)
            }
            let node = SCNNode()
            node.light = light
            node.position = position
            node.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(node)
        }

        func index(of node: SCNNode) -> Int? {
            var current: SCNNode? = node
            while let n = current {
                if let cart = n as? CartridgeNode, let id = nodes.first(where: { $0.value === cart })?.key {
                    return order.firstIndex(of: id)
                }
                current = n.parent
            }
            return nil
        }

        func apply(entries: [GameLibrary.Item], selected: Int, insertingId: String?, tilt: CGPoint,
                   cover: (GameLibrary.Item) -> NSImage?, animated: Bool) {
            let selectionChanged = selected != lastSelected || order != entries.map(\.id)
            lastSelected = selected
            self.tilt = tilt
            order = entries.map(\.id)
            // Cartuchos que saíram da lista.
            for (id, node) in nodes where !order.contains(id) {
                node.removeFromParentNode()
                nodes[id] = nil
                hasCover[id] = nil
            }
            for entry in entries {
                let image = cover(entry)
                if let node = nodes[entry.id] {
                    if hasCover[entry.id] != (image != nil) {
                        node.setLabel(CartridgeLabel.render(title: entry.displayName, cover: image))
                        hasCover[entry.id] = image != nil
                    }
                } else {
                    let node = CartridgeNode(label: CartridgeLabel.render(title: entry.displayName, cover: image))
                    node.opacity = 0
                    scene.rootNode.addChildNode(node)
                    nodes[entry.id] = node
                    hasCover[entry.id] = image != nil
                    // Nasce já na posição, só o fade entra animado.
                    place(node, offset: entries.firstIndex(of: entry)! - selected)
                }
            }

            if let insertingId {
                if insertingId != self.insertingId, let node = nodes[insertingId] {
                    self.insertingId = insertingId
                    insert(node, others: nodes.values.filter { $0 !== node })
                }
                return
            }
            self.insertingId = nil

            SCNTransaction.begin()
            // Só o stick mexendo: resposta curta, senão o cartucho arrasta atrás do dedo.
            SCNTransaction.animationDuration = !animated ? 0 : selectionChanged ? 0.45 : 0.12
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            for (i, entry) in entries.enumerated() {
                guard let node = nodes[entry.id] else { continue }
                place(node, offset: i - selected)
            }
            SCNTransaction.commit()
        }

        /// Encaixe no console: o cartucho vem para a frente, de pé, enquanto os
        /// outros somem; depois desce pelo pé da tela como se entrasse no slot.
        private func insert(_ node: SCNNode, others: [SCNNode]) {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.3
            for other in others { other.opacity = 0 }
            SCNTransaction.commit()
            // Uma volta completa no lugar, para mostrar que é 3D de verdade.
            // SCNAction e não SCNTransaction: a transação interpola rotação
            // como quaternion, e 2π é o mesmo que 0 (não gira nada). Sem
            // o arco mais curto a ação vai pelos ângulos de Euler mesmo:
            // desfaz a inclinação do stick e chega de frente em y = 2π.
            let spin = SCNAction.rotateTo(x: 0.06, y: 2 * .pi, z: 0, duration: 0.7, usesShortestUnitArc: false)
            spin.timingMode = .easeInEaseOut
            node.runAction(spin) {
                DispatchQueue.main.async {
                    // Mesma orientação, sem o 2π acumulado: senão a transação
                    // seguinte "volta" uma volta inteira para a esquerda.
                    SCNTransaction.begin()
                    SCNTransaction.animationDuration = 0
                    node.eulerAngles = SCNVector3(0.06, 0, 0)
                    SCNTransaction.commit()

                    SCNTransaction.begin()
                    SCNTransaction.animationDuration = 0.4
                    SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                    node.position = SCNVector3(0, 0.8, 7)
                    node.scale = SCNVector3(1.08, 1.08, 1.08)
                    node.eulerAngles = SCNVector3(0, 0, 0)
                    SCNTransaction.completionBlock = {
                        // Desce até encostar no rodapé com só a borda de cima
                        // aparecendo e para ali; o jogo entra por cima.
                        SCNTransaction.begin()
                        SCNTransaction.animationDuration = 0.45
                        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        node.position = SCNVector3(0, Coordinator.slotY, 7)
                        node.eulerAngles = SCNVector3(0.12, 0, 0)
                        SCNTransaction.commit()
                    }
                    SCNTransaction.commit()
                }
            }
        }

        /// Posição de cada cartucho pela distância ao escolhido.
        private func place(_ node: SCNNode, offset: Int) {
            let side: CGFloat = offset < 0 ? -1 : 1
            switch abs(offset) {
            case 0:
                // Stick direito: até 28° de giro e 16° de inclinação.
                node.position = SCNVector3(0, 0, 3)
                node.scale = SCNVector3(1, 1, 1)
                node.eulerAngles = SCNVector3(0.06 - tilt.y * 16 * .pi / 180, tilt.x * 28 * .pi / 180, 0)
                node.opacity = 1
            case 1:
                node.position = SCNVector3(side * 12.2, 0, -1)
                node.scale = SCNVector3(0.72, 0.72, 0.72)
                node.eulerAngles = SCNVector3(0.06, -side * 38 * .pi / 180, 0)
                node.opacity = 0.75
            case 2:
                node.position = SCNVector3(side * 19, 0, -6)
                node.scale = SCNVector3(0.55, 0.55, 0.55)
                node.eulerAngles = SCNVector3(0.06, -side * 55 * .pi / 180, 0)
                node.opacity = 0.3
            default:
                node.position = SCNVector3(side * 24, 0, -9)
                node.scale = SCNVector3(0.45, 0.45, 0.45)
                node.eulerAngles = SCNVector3(0.06, -side * 60 * .pi / 180, 0)
                node.opacity = 0
            }
        }
    }
}

/// SCNView que devolve o nó clicado e converte rolagem horizontal em passos.
final class CarouselSCNView: SCNView {
    var onPick: ((SCNNode) -> Void)?
    var onStep: ((Int) -> Void)?
    private var scrollAccumulator: CGFloat = 0

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = hitTest(point, options: [.boundingBoxOnly: true, .firstFoundOnly: true]).first {
            onPick?(hit.node)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : 0
        guard delta != 0 else { return }
        scrollAccumulator += delta
        if event.phase == .ended || event.momentumPhase != [] { return }
        let threshold: CGFloat = 40
        if abs(scrollAccumulator) >= threshold {
            onStep?(scrollAccumulator > 0 ? -1 : 1)
            scrollAccumulator = 0
        }
    }
}
