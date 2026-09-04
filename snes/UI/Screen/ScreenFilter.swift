//  ScreenFilter.swift
//  Modos de filtro retro da tela e seus presets.

import simd

enum ScreenFilter: String, CaseIterable, Identifiable {
    case clean, scanlines, crt, phosphor, phosphorHot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clean: return String(localized: "Clean")
        case .scanlines: return String(localized: "Scanlines")
        case .crt: return String(localized: "CRT glass")
        case .phosphor: return String(localized: "Phosphor")
        case .phosphorHot: return String(localized: "Trinitron")
        }
    }

    var detail: String {
        switch self {
        case .clean: return String(localized: "Pure pixels, no post-processing.")
        case .scanlines: return String(localized: "Sharp pixels with subtle scanlines.")
        case .crt: return String(localized: "Tube curvature, mask, bloom and vignette.")
        case .phosphor: return String(localized: "RGB phosphor grid with localized bleed.")
        case .phosphorHot: return String(localized: "Trinitron-style phosphor stripes, strong glow.")
        }
    }
}

/// Deve casar byte a byte com a struct homônima do RetroShaders.metal.
struct DisplayUniforms {
    var viewportSize = SIMD2<Float>(repeating: 0)
    var textureSize = SIMD2<Float>(repeating: 0)
    var contentOrigin = SIMD2<Float>(repeating: 0)
    var contentSize = SIMD2<Float>(repeating: 0)
    var filterMode: UInt32 = 0
    var integerScalingEnabled: UInt32 = 0
    var scanlineStrength: Float = 0
    var maskStrength: Float = 0
    var bloomStrength: Float = 0
    var curvature: Float = 0
    var vignetteStrength: Float = 0
    var sharpness: Float = 0
    var brightness: Float = 1
    var contrast: Float = 1
    var saturation: Float = 1
    var userSharpness: Float = 1
    var glowAmount: Float = 1
}

extension DisplayUniforms {
    /// Presets por modo (perfil de ajuste padrão: tudo 1.0).
    static func preset(for filter: ScreenFilter, drawableSize: SIMD2<Float>) -> DisplayUniforms {
        var u = DisplayUniforms()
        u.viewportSize = drawableSize
        u.textureSize = SIMD2(256, 224)
        u.contentOrigin = SIMD2(0, 0)
        u.contentSize = drawableSize   // estica como o CALayer fazia (.resize)
        u.integerScalingEnabled = 0

        switch filter {
        case .clean:
            u.filterMode = 0
            u.sharpness = 1
        case .scanlines:
            u.filterMode = 1
            u.scanlineStrength = 0.16
            u.maskStrength = 0.04
            u.bloomStrength = 0.06
            u.vignetteStrength = 0.05
            u.sharpness = 1.35
        case .crt:
            u.filterMode = 2
            u.scanlineStrength = 0.26
            u.maskStrength = 0.11
            u.bloomStrength = 0.18
            u.curvature = 0.08
            u.vignetteStrength = 0.2
            u.sharpness = 1.75
        case .phosphor:
            u.filterMode = 3
            u.maskStrength = 0.2
            u.bloomStrength = 0.52
            u.sharpness = 0.72
        case .phosphorHot:
            u.filterMode = 4
            u.scanlineStrength = 0.18
            u.maskStrength = 0.24
            u.bloomStrength = 0.9
            u.sharpness = 0.5
        }
        return u
    }
}
