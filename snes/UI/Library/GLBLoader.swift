//  GLBLoader.swift
//  Carregador mínimo de glTF binário (.glb) para SceneKit: só malhas
//  triangulares com POSITION/NORMAL/TEXCOORD_0 e índices, sem texturas nem
//  animações. O SceneKit não abre glTF sozinho, e converter para USDZ exigiria
//  ferramenta externa; o modelo do cartucho é simples o bastante para isto.

import Foundation
import SceneKit

enum GLBLoader {
    enum LoadError: Error { case malformed, unsupported }

    private struct Accessor {
        let data: Data
        let count: Int
        let componentType: Int
        let components: Int
        let stride: Int
    }

    /// Geometria da primeira primitiva da primeira malha do arquivo.
    static func geometry(from glb: Data) throws -> SCNGeometry {
        var offset = 12
        var json: [String: Any] = [:]
        var bin = Data()
        while offset + 8 <= glb.count {
            let length = Int(glb.readUInt32(at: offset))
            let type = glb.readUInt32(at: offset + 4)
            let start = offset + 8
            guard start + length <= glb.count else { throw LoadError.malformed }
            let chunk = glb.subdata(in: start..<start + length)
            if type == 0x4E4F534A {
                guard let obj = try JSONSerialization.jsonObject(with: chunk) as? [String: Any] else { throw LoadError.malformed }
                json = obj
            } else if type == 0x004E4942 {
                bin = chunk
            }
            offset = start + length
        }

        guard let meshes = json["meshes"] as? [[String: Any]], let mesh = meshes.first,
              let prims = mesh["primitives"] as? [[String: Any]], let prim = prims.first,
              let attrs = prim["attributes"] as? [String: Int],
              let indicesIndex = prim["indices"] as? Int,
              let accessors = json["accessors"] as? [[String: Any]],
              let views = json["bufferViews"] as? [[String: Any]] else { throw LoadError.malformed }
        if let mode = prim["mode"] as? Int, mode != 4 { throw LoadError.unsupported }

        func accessor(_ index: Int) throws -> Accessor {
            guard index < accessors.count else { throw LoadError.malformed }
            let acc = accessors[index]
            guard let viewIndex = acc["bufferView"] as? Int, viewIndex < views.count,
                  let type = acc["type"] as? String,
                  let componentType = acc["componentType"] as? Int,
                  let count = acc["count"] as? Int else { throw LoadError.malformed }
            let view = views[viewIndex]
            let components: Int
            switch type {
            case "SCALAR": components = 1
            case "VEC2": components = 2
            case "VEC3": components = 3
            case "VEC4": components = 4
            default: throw LoadError.unsupported
            }
            let componentSize: Int
            switch componentType {
            case 5126, 5125: componentSize = 4
            case 5123, 5122: componentSize = 2
            case 5121, 5120: componentSize = 1
            default: throw LoadError.unsupported
            }
            let stride = (view["byteStride"] as? Int) ?? components * componentSize
            let start = ((view["byteOffset"] as? Int) ?? 0) + ((acc["byteOffset"] as? Int) ?? 0)
            let length = stride * (count - 1) + components * componentSize
            guard start + length <= bin.count else { throw LoadError.malformed }
            return Accessor(data: bin.subdata(in: start..<start + length), count: count,
                            componentType: componentType, components: components, stride: stride)
        }

        var sources: [SCNGeometrySource] = []
        for (name, semantic) in [("POSITION", SCNGeometrySource.Semantic.vertex),
                                 ("NORMAL", .normal),
                                 ("TEXCOORD_0", .texcoord)] {
            guard let index = attrs[name] else { continue }
            let a = try accessor(index)
            guard a.componentType == 5126 else { throw LoadError.unsupported }
            sources.append(SCNGeometrySource(data: a.data, semantic: semantic, vectorCount: a.count,
                                             usesFloatComponents: true, componentsPerVector: a.components,
                                             bytesPerComponent: 4, dataOffset: 0, dataStride: a.stride))
        }
        guard !sources.isEmpty else { throw LoadError.malformed }

        let idx = try accessor(indicesIndex)
        let bytesPerIndex: Int
        switch idx.componentType {
        case 5125: bytesPerIndex = 4
        case 5123: bytesPerIndex = 2
        case 5121: bytesPerIndex = 1
        default: throw LoadError.unsupported
        }
        let element = SCNGeometryElement(data: idx.data, primitiveType: .triangles,
                                         primitiveCount: idx.count / 3, bytesPerIndex: bytesPerIndex)
        return SCNGeometry(sources: sources, elements: [element])
    }
}

private extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: offset..<offset + 4) }
        return UInt32(littleEndian: value)
    }
}
