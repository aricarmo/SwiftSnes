//  GameBody.swift
//  Corpo do painel com a ROM carregada: tela do jogo e barra de controles.

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

            ControlsBar(vm: vm, presenter: presenter, gamepad: gamepad)
        }
        .padding(.horizontal, NotchMetrics.contentPadding)
        .padding(.top, 6)
        .padding(.bottom, NotchMetrics.contentPadding)
    }
}

private struct ControlsBar: View {
    @ObservedObject var vm: EmulatorViewModel
    @ObservedObject var presenter: NotchPresenter
    @ObservedObject var gamepad: GamepadInput

    var body: some View {
        HStack(spacing: 7) {
            IconButton(symbol: vm.isRunning ? "pause.fill" : "play.fill", prominent: true,
                       action: vm.togglePlayPause)
            IconButton(symbol: "arrow.counterclockwise", action: vm.reset)
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
