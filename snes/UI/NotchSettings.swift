//  NotchSettings.swift
//  Preferências de comportamento do painel, persistidas em UserDefaults.

import Foundation
import CoreGraphics
import Combine

/// Tamanho da tela do jogo. A faixa que cobre o notch nunca muda de largura;
/// só o corpo abaixo dela alarga para caber o vídeo.
enum ScreenSize: String, CaseIterable, Identifiable {
    case compact, medium, large, cinema

    var id: String { rawValue }

    /// Largura do vídeo em pontos. `nil` = ocupa a largura útil do painel (como sempre foi).
    var videoWidth: CGFloat? {
        switch self {
        case .compact: return nil
        case .medium: return 512
        case .large: return 640
        case .cinema: return 768
        }
    }

    var label: String {
        switch self {
        case .compact: return String(localized: "Compact")
        case .medium: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        case .cinema: return String(localized: "Cinema")
        }
    }

    var detail: String {
        switch self {
        case .compact: return String(localized: "Fits the notch width, as always.")
        case .medium: return String(localized: "2× the SNES video. Only the screen widens; the notch strip stays.")
        case .large: return String(localized: "2.5× the SNES video. Only the screen widens; the notch strip stays.")
        case .cinema: return String(localized: "3× the SNES video. Only the screen widens; the notch strip stays.")
        }
    }
}

@MainActor
final class NotchSettings: ObservableObject {
    static let shared = NotchSettings()

    private enum Key {
        static let pauseOnHide = "notch.pauseOnHide"
        static let audioFade = "notch.audioFade"
        static let clickToOpen = "notch.clickToOpen"
        static let screenSize = "notch.screenSize"
        static let screenFilter = "notch.screenFilter"
        static let retroStyle = "notch.retroStyle"
        static let analogAsDpad = "notch.analogAsDpad"
        static let volume = "notch.volume"
        static let muted = "notch.muted"
    }

    /// Recolher o painel suspende CPU/PPU/APU.
    @Published var pauseOnHide: Bool {
        didSet { defaults.set(pauseOnHide, forKey: Key.pauseOnHide) }
    }
    /// Fade de 150 ms no áudio ao suspender, evita estalo no buffer.
    @Published var audioFade: Bool {
        didSet { defaults.set(audioFade, forKey: Key.audioFade) }
    }
    /// Ignora hover: o painel só abre com clique.
    @Published var clickToOpen: Bool {
        didSet { defaults.set(clickToOpen, forKey: Key.clickToOpen) }
    }
    /// Alavanca esquerda do controle também move o direcional.
    @Published var analogAsDpad: Bool {
        didSet { defaults.set(analogAsDpad, forKey: Key.analogAsDpad) }
    }
    /// Tamanho da tela do jogo.
    @Published var screenSize: ScreenSize {
        didSet { defaults.set(screenSize.rawValue, forKey: Key.screenSize) }
    }
    /// Filtro retro aplicado à tela do jogo. `.clean` = efeito desligado.
    @Published var screenFilter: ScreenFilter {
        didSet {
            defaults.set(screenFilter.rawValue, forKey: Key.screenFilter)
            // Lembra o último estilo retro para religar o efeito no mesmo lugar.
            if screenFilter != .clean {
                defaults.set(screenFilter.rawValue, forKey: Key.retroStyle)
            }
        }
    }

    /// Volume do jogo (0…1), independente do volume do sistema.
    @Published var volume: Double {
        didSet { defaults.set(volume, forKey: Key.volume) }
    }
    /// Silencia o jogo sem perder o nível do slider.
    @Published var muted: Bool {
        didSet { defaults.set(muted, forKey: Key.muted) }
    }

    /// Volume que a saída de áudio deve aplicar de fato.
    var effectiveVolume: Float { muted ? 0 : Float(volume) }

    /// "Efeito TV antiga": desligado é tela limpa; ligado volta ao último estilo.
    var retroEffectEnabled: Bool {
        get { screenFilter != .clean }
        set {
            guard newValue != retroEffectEnabled else { return }
            screenFilter = newValue
                ? ScreenFilter(rawValue: defaults.string(forKey: Key.retroStyle) ?? "") ?? .crt
                : .clean
        }
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.pauseOnHide: true,
            Key.audioFade: true,
            Key.clickToOpen: false,
            Key.analogAsDpad: true,
            Key.volume: 1.0,
            Key.muted: false
        ])
        pauseOnHide = defaults.bool(forKey: Key.pauseOnHide)
        audioFade = defaults.bool(forKey: Key.audioFade)
        clickToOpen = defaults.bool(forKey: Key.clickToOpen)
        analogAsDpad = defaults.bool(forKey: Key.analogAsDpad)
        screenSize = ScreenSize(rawValue: defaults.string(forKey: Key.screenSize) ?? "") ?? .compact
        screenFilter = ScreenFilter(rawValue: defaults.string(forKey: Key.screenFilter) ?? "") ?? .clean
        volume = defaults.double(forKey: Key.volume)
        muted = defaults.bool(forKey: Key.muted)
    }

    var fadeDuration: TimeInterval { audioFade ? 0.15 : 0 }
}
