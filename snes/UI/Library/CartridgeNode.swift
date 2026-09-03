//  CartridgeNode.swift
//  Cartucho SNES em 3D: a malha do arquivo `SNESCartridge` (Steven-Bennis,
//  Sketchfab, CC-BY-4.0) deitada, com a etiqueta encaixada no rebaixo do rótulo.

import AppKit
import SceneKit

enum CartridgeModel {
    /// Largura do cartucho na cena, em cm (136 mm).
    static let width: CGFloat = 13.6
    static let height: CGFloat = 8.8

    /// Rebaixo do rótulo no espaço do modelo (medido nos vértices da malha).
    private static let labelPlaneZ: CGFloat = 0.709
    private static let labelX: ClosedRange<CGFloat> = -1.607...(-0.090)
    private static let labelY: ClosedRange<CGFloat> = -1.616...1.616

    /// Geometria compartilhada por todos os cartuchos; nil se o asset faltar.
    static let geometry: SCNGeometry? = {
        guard let asset = NSDataAsset(name: "SNESCartridge") else { return nil }
        guard let geometry = try? GLBLoader.geometry(from: asset.data) else { return nil }
        geometry.materials = [plastic(NSColor(calibratedRed: 0.60, green: 0.60, blue: 0.63, alpha: 1))]
        return geometry
    }()

    static func plastic(_ color: NSColor, roughness: CGFloat = 0.6) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = 0.0
        return m
    }
}

/// Nó raiz de um cartucho: já deitado, centrado e na escala em cm.
final class CartridgeNode: SCNNode {
    private let labelMaterial = SCNMaterial()

    init(label: NSImage) {
        super.init()
        guard let geometry = CartridgeModel.geometry else { return }
        let (bmin, bmax) = geometry.boundingBox
        let center = SCNVector3((bmin.x + bmax.x) / 2, (bmin.y + bmax.y) / 2, (bmin.z + bmax.z) / 2)
        // O arquivo vem em pé, com a corcova para -X: o eixo longo é Y.
        let scale = CartridgeModel.width / CGFloat(bmax.y - bmin.y)

        let mesh = SCNNode(geometry: geometry)
        mesh.position = SCNVector3(-center.x, -center.y, -center.z)

        labelMaterial.lightingModel = .physicallyBased
        labelMaterial.roughness.contents = 0.3
        labelMaterial.metalness.contents = 0.0
        labelMaterial.diffuse.contents = label
        let black = CartridgeModel.plastic(.black)
        let labelBox = SCNBox(width: 1.616 * 2 - 0.03, height: 1.607 - 0.090 - 0.03, length: 0.01, chamferRadius: 0)
        labelBox.materials = [labelMaterial, black, black, black, black, black]
        let labelNode = SCNNode(geometry: labelBox)
        labelNode.position = SCNVector3((-1.607 + -0.090) / 2, 0, 0.709 + 0.006)
        labelNode.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
        mesh.addChildNode(labelNode)

        let upright = SCNNode()
        upright.addChildNode(mesh)
        upright.eulerAngles = SCNVector3(0, 0, -CGFloat.pi / 2)
        upright.scale = SCNVector3(scale, scale, scale)
        addChildNode(upright)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    func setLabel(_ image: NSImage) {
        labelMaterial.diffuse.contents = image
    }
}
