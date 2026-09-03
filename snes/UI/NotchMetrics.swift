//  NotchMetrics.swift
//  Geometria do painel ancorado no notch.

import AppKit
import SwiftUI

enum NotchMetrics {
    /// Altura da faixa quando nem o entalhe nem a barra de menus dão a medida
    /// (barra de menus oculta). Nos demais casos a faixa usa a altura exata
    /// deles: um piso fixo deixava a pílula invadindo as janelas de baixo.
    static let fallbackHeaderHeight: CGFloat = 37
    static let bottomCornerRadius: CGFloat = 26
    /// Raio dos cantos inferiores do entalhe físico dos MacBooks.
    static let notchCornerRadius: CGFloat = 11
    static let contentPadding: CGFloat = 12
    static let controlsHeight: CGFloat = 32
    /// Espaço mínimo de cada lado do entalhe para caber título e FPS.
    static let minSideWidth: CGFloat = 95
    static let minPanelWidth: CGFloat = 380
    /// Raio dos ombros onde o corpo, mais largo, sai de baixo da faixa do notch.
    static let shoulderRadius: CGFloat = 14
    /// Raio das orelhas côncavas onde o topo da faixa encosta na borda da tela,
    /// como o entalhe físico. Sem elas o painel parece uma lingueta colada.
    static let topFlareRadius: CGFloat = 20
    /// Mesmas orelhas na pílula recolhida, bem menores.
    static let pillFlareRadius: CGFloat = 6

    /// Margem da janela em volta do painel, para a sombra não ser recortada.
    static let shadowMargin: CGFloat = 44
    static let shadowRadius: CGFloat = 22

    static let emptyDropHeight: CGFloat = 148

    /// Biblioteca (carrossel de cartuchos): mesma largura do vídeo "Grande",
    /// para três cartuchos caberem lado a lado com folga.
    static let libraryBodyWidth: CGFloat = 664
    static let libraryCarouselHeight: CGFloat = 236

    /// Miniatura do tamanho de tela nos ajustes: largura do corpo interpola
    /// entre o vídeo compacto (356 pt) e o cinema (768 pt).
    static let sizeGlyphMinWidth: CGFloat = 26
    static func sizeGlyphWidth(forVideoWidth width: CGFloat) -> CGFloat {
        let t = (width - 356) / (768 - 356)
        return max(sizeGlyphMinWidth, sizeGlyphMinWidth + 18 * t)
    }
    static let settingsBodyHeight: CGFloat = 399

    // MARK: - Animação

    /// Duração única para janela e conteúdo: se divergirem, o texto aparece
    /// antes de haver espaço para ele.
    static let expandDuration: TimeInterval = 0.6
    /// easeOutQuint: sai rápido e assenta devagar, sem o freio seco do easeOut padrão.
    static var frameTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    }
    static var contentAnimation: Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: expandDuration)
    }
    /// Abrir e fechar em duas etapas: a faixa alarga e só então o corpo desce;
    /// ao fechar o corpo sobe e só então a faixa estreita.
    static let widthDuration: TimeInterval = 0.3
    static var widthAnimation: Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: widthDuration)
    }
    /// Quanto esperar antes da segunda etapa: easeOutQuint já está
    /// praticamente assentado bem antes do fim, e as etapas se sobrepõem.
    static let expandHeightDelay: TimeInterval = widthDuration * 0.4
    static let collapseWidthDelay: TimeInterval = expandDuration * 0.7
    /// Tempo total de abrir (largura + altura) ou fechar (altura + largura).
    static let totalDuration: TimeInterval = widthDuration + expandDuration

    /// Tela que tem o entalhe; se nenhuma tiver, a principal.
    static func preferredScreen() -> NSScreen {
        // NOTCH_SCREEN=1 põe o painel na segunda tela: serve para testar duas
        // cópias do app (anfitrião e convidado) na mesma máquina.
        if let index = ProcessInfo.processInfo.environment["NOTCH_SCREEN"].flatMap(Int.init),
           NSScreen.screens.indices.contains(index) {
            return NSScreen.screens[index]
        }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    static func headerHeight(on screen: NSScreen) -> CGFloat {
        if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
        // Sem notch, a pílula não deve passar da barra de menus.
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return menuBar > 0 ? menuBar : fallbackHeaderHeight
    }

    /// Largura do entalhe físico. Zero em Macs sem notch.
    static func notchWidth(on screen: NSScreen) -> CGFloat {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return 0 }
        return max(0, screen.frame.width - left.width - right.width)
    }

    /// Largura do entalhe dos MacBooks com notch, usada como pílula recolhida
    /// em telas sem notch (monitor externo): o painel se comporta igual nas duas.
    static let virtualNotchWidth: CGFloat = 185

    /// Largura da faixa recolhida: só o entalhe físico. Sem notch, uma pílula
    /// do tamanho do entalhe de um MacBook; o cabeçalho alarga no hover.
    static func collapsedWidth(panelWidth: CGFloat, notchGap: CGFloat) -> CGFloat {
        min(panelWidth, notchGap > 0 ? notchGap : virtualNotchWidth)
    }

    static func panelWidth(on screen: NSScreen) -> CGFloat {
        max(minPanelWidth, notchWidth(on: screen) + minSideWidth * 2)
    }

    /// Área de vídeo em 4:3. No tamanho compacto ocupa a largura útil da
    /// faixa do notch; nos demais tem largura própria, e o corpo cresce para caber.
    static func videoSize(panelWidth: CGFloat, size: ScreenSize) -> CGSize {
        let w = (size.videoWidth ?? (panelWidth - contentPadding * 2)).rounded()
        return CGSize(width: w, height: (w * 3 / 4).rounded())
    }

    /// Largura do corpo com o jogo aberto: nunca menor que a faixa do notch.
    static func bodyWidth(panelWidth: CGFloat, size: ScreenSize) -> CGFloat {
        max(panelWidth, videoSize(panelWidth: panelWidth, size: size).width + contentPadding * 2)
    }

    /// Largura da janela: o maior corpo possível (jogo ou biblioteca). O
    /// conteúdo mais estreito fica centralizado nela.
    static func windowWidth(panelWidth: CGFloat, size: ScreenSize) -> CGFloat {
        max(bodyWidth(panelWidth: panelWidth, size: size), libraryBodyWidth)
    }
}
