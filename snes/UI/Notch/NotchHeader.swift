//  NotchHeader.swift
//  Faixa que cobre o notch: título/ícone à esquerda, estado (FPS, pausa, ajustes) à direita.

import SwiftUI

struct NotchHeader: View {
    @ObservedObject var vm: EmulatorViewModel
    @ObservedObject var presenter: NotchPresenter
    @ObservedObject var gamepad: GamepadInput

    let panelWidth: CGFloat
    let headerHeight: CGFloat
    let notchGap: CGFloat

    /// Respiro lateral: entra no cálculo da metade, senão a soma dos lados já é
    /// a largura do painel e o padding empurra o texto para fora.
    static let horizontalPadding: CGFloat = 16

    private var sideWidth: CGFloat {
        max(0, (panelWidth - notchGap) / 2 - Self.horizontalPadding)
    }

    var body: some View {
        HStack(spacing: 0) {
            NotchHeaderLeading(vm: vm, presenter: presenter)
                .frame(width: sideWidth, alignment: .leading)
            Spacer(minLength: 0)
                .frame(width: notchGap)
            NotchHeaderTrailing(vm: vm, presenter: presenter, gamepad: gamepad)
                .frame(width: sideWidth, alignment: .trailing)
        }
        .padding(.horizontal, Self.horizontalPadding)
        // Recolhido o painel é só preto: nada de título, FPS ou ícone. Com o
        // cursor em cima, o cabeçalho surge sozinho; o corpo só vem com clique.
        .opacity(presenter.showsHeader ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: presenter.showsHeader)
        // Recolhido, avisa por alguns segundos que um controle acabou de parear.
        .overlay(alignment: .trailing) {
            if gamepad.justConnected && !presenter.showsHeader {
                GamepadBadge(text: "conectado")
                    .padding(.trailing, Self.horizontalPadding)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: gamepad.justConnected)
        .frame(width: panelWidth, height: headerHeight)
    }
}

private struct NotchHeaderLeading: View {
    @ObservedObject var vm: EmulatorViewModel
    @ObservedObject var presenter: NotchPresenter

    var body: some View {
        if presenter.showsSettings {
            Button(action: closeSettings) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Ajustes")
                        .font(.system(size: 11))
                }
                .foregroundStyle(NotchPalette.primaryText.opacity(0.8))
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 7) {
                Image("CartridgeGlyph")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .foregroundStyle(vm.isROMLoaded ? NotchPalette.accentSoft : Color.white.opacity(0.4))
                Text(vm.isROMLoaded ? vm.shortTitle : "SNES")
                    .font(.system(size: 10.5, design: .monospaced))
                    .kerning(0.6)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(NotchPalette.primaryText.opacity(vm.isROMLoaded ? 0.86 : 0.45))
            }
        }
    }

    private func closeSettings() {
        presenter.showsSettings = false
    }
}

private struct NotchHeaderTrailing: View {
    @ObservedObject var vm: EmulatorViewModel
    @ObservedObject var presenter: NotchPresenter
    @ObservedObject var gamepad: GamepadInput

    var body: some View {
        if !vm.isROMLoaded {
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .buttonStyle(.plain)
        } else if vm.isRunning {
            HStack(spacing: 6) {
                if gamepad.isConnected {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.55))
                }
                Circle()
                    .fill(NotchPalette.running)
                    .frame(width: 6, height: 6)
                    .shadow(color: NotchPalette.running.opacity(0.7), radius: 4)
                Text("\(Int(vm.fps.rounded())) FPS")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.9))
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "pause.fill")
                    .font(.system(size: 9))
                Text("PAUSADO")
                    .font(.system(size: 10.5, design: .monospaced))
            }
            .foregroundStyle(NotchPalette.primaryText.opacity(0.55))
        }
    }

    private func openSettings() {
        presenter.showsSettings = true
    }
}

/// Ícone de controle com texto mono, no mesmo tom do FPS.
struct GamepadBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 10))
                .foregroundStyle(NotchPalette.accentSoft)
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(NotchPalette.primaryText.opacity(0.86))
        }
    }
}
