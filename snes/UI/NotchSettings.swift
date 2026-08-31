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
        case .compact: return "Compacto"
        case .medium: return "Médio"
        case .large: return "Grande"
        case .cinema: return "Cinema"
        }
    }

    var detail: String {
        switch self {
        case .compact: return "Cabe na largura do notch, como sempre."
        case .medium: return "2× o vídeo do SNES. Só a tela alarga; a faixa do notch não muda."
        case .large: return "2,5× o vídeo do SNES. Só a tela alarga; a faixa do notch não muda."
        case .cinema: return "3× o vídeo do SNES. Só a tela alarga; a faixa do notch não muda."
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
            Key.analogAsDpad: true
        ])
        pauseOnHide = defaults.bool(forKey: Key.pauseOnHide)
        audioFade = defaults.bool(forKey: Key.audioFade)
        clickToOpen = defaults.bool(forKey: Key.clickToOpen)
        analogAsDpad = defaults.bool(forKey: Key.analogAsDpad)
        screenSize = ScreenSize(rawValue: defaults.string(forKey: Key.screenSize) ?? "") ?? .compact
        screenFilter = ScreenFilter(rawValue: defaults.string(forKey: Key.screenFilter) ?? "") ?? .clean
    }

    var fadeDuration: TimeInterval { audioFade ? 0.15 : 0 }
}
