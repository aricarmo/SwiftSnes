//  GameBody.swift
//  Corpo do painel com a ROM carregada: tela do jogo, fita de voltar no tempo
//  e barra de controles.

import SwiftUI

struct GameBody: View {
    @ObservedObject var vm: EmulatorViewModel
    @ObservedObject var presenter: NotchPresenter
    @ObservedObject var gamepad: GamepadInput

    let videoSize: CGSize

    var body: some View {
        VStack(spacing: 8) {
            ScreenView(source: vm.frameSource)
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

            if let session = vm.rewind {
                RewindStrip(session: session, width: videoSize.width,
                            onSelect: vm.rewindSelect, onConfirm: vm.rewindConfirm, onCancel: vm.rewindCancel)
            }

            ControlsBar(vm: vm, presenter: presenter, gamepad: gamepad)
        }
        .padding(.horizontal, NotchMetrics.contentPadding)
        .padding(.top, 6)
        .padding(.bottom, NotchMetrics.contentPadding)
    }
}

// MARK: - Voltar no tempo

private struct RewindBadge: View {
    let seconds: Double

    var body: some View {
        Text(seconds > -0.05 ? "agora" : String(format: "−%.1f s", -seconds))
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
                SectionLabel("ÚLTIMOS 10 SEGUNDOS")
                Spacer(minLength: 0)
                if width >= 480 {
                    Text("← → escolhe · ⇧ ajuste fino · ↩ / B volta · esc / A cancela")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.45))
                        .lineLimit(1)
                }
                StripButton(text: "Voltar aqui", prominent: true, action: onConfirm)
                StripButton(text: "Cancelar", prominent: false, action: onCancel)
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
                            Text(thumb.secondsAgo == 0 ? "agora" : String(format: "−%.0f s", thumb.secondsAgo))
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
    let text: String
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
        f.locale = Locale(identifier: "pt_BR")
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchPalette.accentSoft)
            Text("Continuando de \(Self.formatter.localizedString(for: notice.savedAt, relativeTo: Date()))")
                .font(.system(size: 11))
                .foregroundStyle(NotchPalette.primaryText.opacity(0.9))
                .lineLimit(1)
            Button("Começar do zero", action: onRestart)
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

            Spacer(minLength: 0)

            if gamepad.isConnected {
                HStack(spacing: 5) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 11))
                        .foregroundStyle(NotchPalette.accentSoft)
                    Text(gamepad.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
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
