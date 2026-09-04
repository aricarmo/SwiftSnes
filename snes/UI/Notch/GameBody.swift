//  GameBody.swift
//  Corpo do painel com a ROM carregada: tela do jogo, fita de voltar no tempo
//  e barra de controles.

import SwiftUI

struct GameBody: View {
    @ObservedObject var vm: EmulatorViewModel
    @ObservedObject var presenter: NotchPresenter
    @ObservedObject var gamepad: GamepadInput

    let videoSize: CGSize
    let filter: ScreenFilter

    @ObservedObject private var settings = NotchSettings.shared
    /// OSD de volume composto no framebuffer; some sozinho com fade.
    @State private var osdAlpha: Double = 0
    @State private var osdFade: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 8) {
            ScreenView(source: vm.frameSource, filter: filter,
                       osd: osdAlpha > 0
                           ? VolumeOSDRaster.overlay(volume: settings.volume,
                                                     muted: settings.muted,
                                                     alpha: osdAlpha)
                           : nil)
                .frame(width: videoSize.width, height: videoSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if let session = vm.rewind {
                        RewindBadge(seconds: session.offsetSeconds)
                            .padding(10)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let notice = vm.resumeNotice, vm.rewind == nil {
                        ResumeNoticeRow(notice: notice, onRestart: vm.reset, onDismiss: vm.dismissResumeNotice)
                            .padding(10)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: vm.resumeNotice)
                .onChange(of: settings.volume) { _, _ in showVolumeOSD() }
                .onChange(of: settings.muted) { _, _ in showVolumeOSD() }

            if let session = vm.rewind {
                RewindStrip(session: session, width: videoSize.width,
                            onSelect: vm.rewindSelect, onConfirm: vm.rewindConfirm, onCancel: vm.rewindCancel)
            }

            // Mesma largura da tela: sem isso o nome do gamepad alarga a barra
            // além do painel e os botões da direita saem cortados.
            ControlsBar(vm: vm, presenter: presenter, gamepad: gamepad)
                .frame(width: videoSize.width)
        }
        .padding(.horizontal, NotchMetrics.contentPadding)
        .padding(.top, 6)
        .padding(.bottom, NotchMetrics.contentPadding)
    }

    private func showVolumeOSD() {
        osdFade?.cancel()
        osdAlpha = 1
        osdFade = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            for step in stride(from: 0.75, through: 0, by: -0.25) {
                osdAlpha = step
                guard step > 0 else { break }
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
            }
        }
    }
}

// MARK: - Volume

/// OSD estilo TV antiga ("VOLUME" verde e blocos), rasterizado em pixels do
/// framebuffer 256×224 e composto no frame antes dos shaders: assim scanlines,
/// curvatura e fósforo também o afetam, igual a um OSD de TV de verdade.
private enum VolumeOSDRaster {
    private static let blocks = 15
    private static let scale = 3          // fonte 3×5 desenhada em 9×15 px
    private static let barW = 4, barH = 14, barGap = 2
    private static let shadowOffset = 2
    private static let width = blocks * (barW + barGap) - barGap + shadowOffset
    private static let height = 5 * scale + 4 + barH + shadowOffset

    private static let green: (UInt8, UInt8, UInt8, UInt8) = (53, 255, 109, 255) // #35ff6d
    private static let greenDim: (UInt8, UInt8, UInt8, UInt8) = (12, 56, 24, 56) // 22%
    private static let shadow: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 217)
    private static let shadowDim: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 48)

    /// Fonte 3×5, bit mais alto = coluna da esquerda.
    private static let glyphs: [Character: [UInt8]] = [
        "V": [0b101, 0b101, 0b101, 0b101, 0b010],
        "O": [0b111, 0b101, 0b101, 0b101, 0b111],
        "L": [0b100, 0b100, 0b100, 0b100, 0b111],
        "U": [0b101, 0b101, 0b101, 0b101, 0b111],
        "M": [0b101, 0b111, 0b101, 0b101, 0b101],
        "E": [0b111, 0b100, 0b110, 0b100, 0b111],
        "D": [0b110, 0b101, 0b101, 0b101, 0b110],
        "T": [0b111, 0b010, 0b010, 0b010, 0b010],
    ]

    static func overlay(volume: Double, muted: Bool, alpha: Double) -> FrameOverlay {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let filled = muted ? 0 : min(blocks, Int((volume * Double(blocks)).rounded()))

        let text = muted ? String(localized: "MUTE") : "VOLUME"
        drawText(text, into: &px, x: shadowOffset, y: shadowOffset, color: shadow)
        drawText(text, into: &px, x: 0, y: 0, color: green)

        let barsY = 5 * scale + 4
        for i in 0..<blocks {
            let x = i * (barW + barGap)
            let lit = i < filled
            fill(&px, x: x + shadowOffset, y: barsY + shadowOffset, w: barW, h: barH,
                 color: lit ? shadow : shadowDim)
            fill(&px, x: x, y: barsY, w: barW, h: barH, color: lit ? green : greenDim)
        }

        return FrameOverlay(x: 12, y: FrameOverlay.frameHeight - height - 12,
                            width: width, height: height,
                            alpha: Float(alpha), pixels: px)
    }

    private static func drawText(_ text: String, into px: inout [UInt8],
                                 x: Int, y: Int,
                                 color: (UInt8, UInt8, UInt8, UInt8)) {
        var cx = x
        for ch in text {
            guard let rows = glyphs[ch] else { continue }
            for (ry, bits) in rows.enumerated() {
                for bx in 0..<3 where bits & (0b100 >> bx) != 0 {
                    fill(&px, x: cx + bx * scale, y: y + ry * scale,
                         w: scale, h: scale, color: color)
                }
            }
            cx += 3 * scale + 2
        }
    }

    private static func fill(_ px: inout [UInt8], x: Int, y: Int, w: Int, h: Int,
                             color: (UInt8, UInt8, UInt8, UInt8)) {
        for row in y..<min(y + h, height) where row >= 0 {
            for col in x..<min(x + w, width) where col >= 0 {
                let i = (row * width + col) * 4
                px[i] = color.0
                px[i + 1] = color.1
                px[i + 2] = color.2
                px[i + 3] = color.3
            }
        }
    }
}

/// Alto-falante que silencia no clique + slider de volume ao lado.
private struct VolumeControl: View {
    @ObservedObject var settings: NotchSettings

    private var symbol: String {
        if settings.muted { return "speaker.slash.fill" }
        switch settings.volume {
        case ..<0.05: return "speaker.fill"
        case ..<0.4: return "speaker.wave.1.fill"
        case ..<0.75: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: symbol, active: settings.muted,
                       action: { settings.muted.toggle() })
            Slider(value: Binding(
                get: { settings.muted ? 0 : settings.volume },
                set: { newValue in
                    settings.volume = newValue
                    if settings.muted, newValue > 0 { settings.muted = false }
                }
            ), in: 0...1)
            .controlSize(.mini)
            .tint(NotchPalette.accent)
            .frame(width: 72)
        }
    }
}

// MARK: - Voltar no tempo

private struct RewindBadge: View {
    let seconds: Double

    var body: some View {
        Text(seconds > -0.05 ? String(localized: "now") : String(format: "−%.1f s", -seconds))
            .font(.system(size: 10.5))
            .monospacedDigit()
            .kerning(0.6)
            .foregroundStyle(NotchPalette.accentBright)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(NotchPalette.accentSoft.opacity(0.5), lineWidth: 1)
            )
    }
}

/// Miniaturas dos últimos 10 s, uma a cada 2 s, mais o "agora".
private struct RewindStrip: View {
    let session: EmulatorViewModel.RewindSession
    let width: CGFloat
    let onSelect: (Int) -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private static let marks: [Double] = [10, 8, 6, 4, 2, 0]
    private static let thumbAspect: CGFloat = 3.0 / 4.0

    private struct Thumb: Identifiable {
        let id: Int
        let secondsAgo: Double
        let index: Int
        let image: CGImage?
    }

    private var thumbs: [Thumb] {
        Self.marks.enumerated().compactMap { i, seconds in
            guard let index = session.index(secondsAgo: seconds) else { return nil }
            return Thumb(id: i, secondsAgo: seconds, index: index, image: session.entries[index].image)
        }
    }

    /// Miniatura mais próxima do snapshot exibido.
    private var highlighted: Int? {
        thumbs.min { abs($0.index - session.index) < abs($1.index - session.index) }?.id
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                SectionLabel("LAST 10 SECONDS")
                Spacer(minLength: 0)
                if width >= 480 {
                    Text("← → pick · ⇧ fine-tune · ↩ / B rewind · esc / A cancel")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.45))
                        .lineLimit(1)
                }
                StripButton(text: "Rewind here", prominent: true, action: onConfirm)
                StripButton(text: "Cancel", prominent: false, action: onCancel)
            }

            let items = thumbs
            let gap: CGFloat = 6
            let thumbWidth = ((width - 20 - gap * CGFloat(max(1, items.count) - 1)) / CGFloat(max(1, items.count))).rounded(.down)
            HStack(alignment: .top, spacing: gap) {
                ForEach(items) { thumb in
                    let selected = thumb.id == highlighted
                    Button(action: { onSelect(thumb.index) }) {
                        VStack(spacing: 4) {
                            ThumbImage(image: thumb.image)
                                .frame(width: thumbWidth, height: (thumbWidth * Self.thumbAspect).rounded())
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(selected ? NotchPalette.accentSoft : Color.white.opacity(0.08),
                                                      lineWidth: selected ? 2 : 1)
                                )
                                .opacity(selected ? 1 : 0.55)
                            Text(thumb.secondsAgo == 0 ? String(localized: "now") : String(format: "−%.0f s", thumb.secondsAgo))
                                .font(.system(size: 9.5))
                                .foregroundStyle(selected ? NotchPalette.accentBright : NotchPalette.primaryText.opacity(0.4))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(10)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(NotchPalette.accent.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(NotchPalette.accentSoft.opacity(0.38), lineWidth: 1)
        )
    }
}

private struct ThumbImage: View {
    let image: CGImage?

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fill)
        } else {
            Color.white.opacity(0.06)
        }
    }
}

private struct StripButton: View {
    let text: LocalizedStringKey
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 10.5, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? NotchPalette.accentBright : NotchPalette.primaryText.opacity(0.7))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(prominent ? NotchPalette.accent.opacity(0.28) : Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(prominent ? NotchPalette.accentSoft.opacity(0.55) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Retomada

private struct ResumeNoticeRow: View {
    let notice: EmulatorViewModel.ResumeNotice
    let onRestart: () -> Void
    let onDismiss: () -> Void

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchPalette.accentSoft)
            Text("Resuming from \(Self.formatter.localizedString(for: notice.savedAt, relativeTo: Date()))")
                .font(.system(size: 11))
                .foregroundStyle(NotchPalette.primaryText.opacity(0.9))
                .lineLimit(1)
            Button("Start over", action: onRestart)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(NotchPalette.accentBright)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.5))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(NotchPalette.accentSoft.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Controles

private struct ControlsBar: View {
    @ObservedObject var vm: EmulatorViewModel
    @ObservedObject var presenter: NotchPresenter
    @ObservedObject var gamepad: GamepadInput

    var body: some View {
        HStack(spacing: 7) {
            IconButton(symbol: vm.isRunning ? "pause.fill" : "play.fill", prominent: true,
                       action: vm.togglePlayPause)
            IconButton(symbol: "arrow.counterclockwise", action: vm.reset)
            IconButton(symbol: "backward.fill", active: vm.rewind != nil, action: vm.toggleRewind)
            IconButton(symbol: "folder", action: vm.showFileDialog)
            VolumeControl(settings: NotchSettings.shared)

            Spacer(minLength: 0)

            if gamepad.isConnected {
                HStack(spacing: 5) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 11))
                        .foregroundStyle(NotchPalette.accentSoft)
                    Text(gamepad.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.72))
                }
                .padding(.trailing, 4)
            }

            IconButton(symbol: presenter.isPinned ? "pin.fill" : "pin", active: presenter.isPinned,
                       action: presenter.togglePin)
            IconButton(symbol: "gearshape", action: openSettings)
        }
        .frame(height: NotchMetrics.controlsHeight)
    }

    private func openSettings() {
        presenter.showsSettings = true
    }
}

struct IconButton: View {
    let symbol: String
    var prominent = false
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? NotchPalette.accentBright
                                 : NotchPalette.primaryText.opacity(prominent ? 1 : 0.8))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(active ? NotchPalette.accent.opacity(0.28)
                              : Color.white.opacity(prominent ? 0.11 : 0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(active ? NotchPalette.accentSoft.opacity(0.55) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
