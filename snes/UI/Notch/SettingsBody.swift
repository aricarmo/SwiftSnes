//  SettingsBody.swift
//  Subpainel de ajustes: teclas/controle, tamanho da tela e comportamento.

import SwiftUI

/// Qual fonte de entrada a grade de botões está mostrando.
enum InputSource: String, CaseIterable, Identifiable {
    case keyboard, gamepad
    var id: String { rawValue }
    var label: String { self == .keyboard ? "Teclado" : "Controle" }
}

struct SettingsBody: View {
    @ObservedObject var presenter: NotchPresenter
    @ObservedObject var settings: NotchSettings
    @ObservedObject var bindings: KeyBindings
    @ObservedObject var padBindings: GamepadBindings
    @ObservedObject var gamepad: GamepadInput

    let panelWidth: CGFloat
    let onQuit: () -> Void

    @State private var source: InputSource = .keyboard

    private static let bindingColumns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    private static let sizeColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: ScreenSize.allCases.count)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SectionLabel("CONTROLES")
                Spacer()
                SourcePicker(source: $source)
            }

            GamepadStatusRow(gamepad: gamepad)

            LazyVGrid(columns: Self.bindingColumns, spacing: 6) {
                ForEach(SNESButton.displayOrder) { button in
                    BindingRow(button: button,
                               keyLabel: label(for: button),
                               isRebinding: isRebinding(button),
                               onTap: { toggleRebinding(button) })
                }
                DirectionRow(text: source == .keyboard ? "setas" : "d-pad")
            }

            if source == .gamepad {
                SettingToggleRow(title: "Analógico como direcional",
                                 detail: "Alavanca esquerda também move o d-pad",
                                 isOn: $settings.analogAsDpad)
            }

            Divider().overlay(NotchPalette.divider)
            SectionLabel("TELA")

            LazyVGrid(columns: Self.sizeColumns, spacing: 6) {
                ForEach(ScreenSize.allCases) { size in
                    ScreenSizeCard(size: size,
                                   videoSize: NotchMetrics.videoSize(panelWidth: panelWidth, size: size),
                                   isSelected: settings.screenSize == size,
                                   onSelect: { settings.screenSize = size })
                }
            }
            Text(settings.screenSize.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(NotchPalette.primaryText.opacity(0.4))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(NotchPalette.divider)
            SectionLabel("COMPORTAMENTO")

            SettingToggleRow(title: "Pausar ao recolher",
                             detail: "Suspende CPU, PPU e APU quando o painel fecha",
                             isOn: $settings.pauseOnHide)
            SettingToggleRow(title: "Fade de áudio",
                             detail: "150 ms ao pausar, evita estalo no buffer",
                             isOn: $settings.audioFade)
            SettingToggleRow(title: "Abrir só com clique",
                             detail: "Ignora hover, expande apenas ao clicar",
                             isOn: $settings.clickToOpen)

            HStack {
                Button("Restaurar controles", action: restoreDefaults)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchPalette.accentSoft)
                Spacer()
                Button("Sair", action: onQuit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.5))
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, NotchMetrics.contentPadding)
        .padding(.top, 4)
        .frame(width: panelWidth, alignment: .leading)
        .onAppear { if gamepad.isConnected { source = .gamepad } }
        .onChange(of: source) { _, _ in
            presenter.rebindingButton = nil
            presenter.rebindingPadButton = nil
        }
    }

    private func label(for button: SNESButton) -> String {
        switch source {
        case .keyboard: return bindings.label(for: button)
        case .gamepad: return padBindings.element(for: button)?.label(in: gamepad.controller) ?? "nenhum"
        }
    }

    private func isRebinding(_ button: SNESButton) -> Bool {
        switch source {
        case .keyboard: return presenter.rebindingButton == button
        case .gamepad: return presenter.rebindingPadButton == button
        }
    }

    private func toggleRebinding(_ button: SNESButton) {
        switch source {
        case .keyboard:
            presenter.rebindingButton = presenter.rebindingButton == button ? nil : button
        case .gamepad:
            guard gamepad.isConnected else { return }
            presenter.rebindingPadButton = presenter.rebindingPadButton == button ? nil : button
        }
    }

    private func restoreDefaults() {
        switch source {
        case .keyboard: bindings.restoreDefaults()
        case .gamepad: padBindings.restoreDefaults()
        }
    }
}

// MARK: - Controle

private struct SourcePicker: View {
    @Binding var source: InputSource

    var body: some View {
        HStack(spacing: 2) {
            ForEach(InputSource.allCases) { item in
                Button(action: { source = item }) {
                    Text(item.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(source == item ? NotchPalette.accentBright
                                         : NotchPalette.primaryText.opacity(0.5))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(source == item ? NotchPalette.accent.opacity(0.22) : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}

private struct GamepadStatusRow: View {
    @ObservedObject var gamepad: GamepadInput

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 11))
                .foregroundStyle(gamepad.isConnected ? NotchPalette.accentSoft : Color.white.opacity(0.3))
            if gamepad.isConnected {
                Text(gamepad.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.85))
                Spacer()
                if let level = gamepad.batteryLevel, level >= 0 {
                    Text("\(Int((level * 100).rounded()))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.38))
                }
                Circle()
                    .fill(NotchPalette.running)
                    .frame(width: 6, height: 6)
                    .shadow(color: NotchPalette.running.opacity(0.7), radius: 3)
                Text("conectado")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.9))
            } else {
                Text("Nenhum controle")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.45))
                Spacer()
                Text("Bluetooth ou USB")
                    .font(.system(size: 10.5))
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.3))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(gamepad.isConnected ? Color.white.opacity(0.05) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(gamepad.isConnected ? .clear : Color.white.opacity(0.12),
                              style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        )
    }
}

// MARK: - Linhas

private struct BindingRow: View {
    let button: SNESButton
    let keyLabel: String
    let isRebinding: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Text(button.label)
                    .font(.system(size: 12))
                    .foregroundStyle(isRebinding ? NotchPalette.accentBright
                                     : NotchPalette.primaryText.opacity(0.72))
                Spacer()
                KeyCap(text: isRebinding ? "pressione…" : keyLabel, highlighted: isRebinding)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isRebinding ? NotchPalette.accent.opacity(0.16) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isRebinding ? NotchPalette.accentSoft.opacity(0.55) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// O direcional é fixo (setas / d-pad): linha só informativa.
private struct DirectionRow: View {
    let text: String

    var body: some View {
        HStack {
            Text("Direcional")
                .font(.system(size: 12))
                .foregroundStyle(NotchPalette.primaryText.opacity(0.72))
            Spacer()
            KeyCap(text: text, highlighted: false)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }
}

private struct KeyCap: View {
    let text: String
    let highlighted: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .lineLimit(1)
            .foregroundStyle(highlighted ? NotchPalette.accentBright : NotchPalette.primaryText.opacity(0.9))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(highlighted ? NotchPalette.accentSoft.opacity(0.18) : Color.white.opacity(0.09))
            )
    }
}

private struct ScreenSizeCard: View {
    let size: ScreenSize
    let videoSize: CGSize
    let isSelected: Bool
    let onSelect: () -> Void

    private var glyphColor: Color {
        isSelected ? NotchPalette.accentSoft : Color.white.opacity(0.28)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                // Miniatura: faixa do notch fixa em cima, corpo proporcional embaixo.
                VStack(spacing: -1) {
                    UnevenRoundedRectangle(bottomLeadingRadius: 2, bottomTrailingRadius: 2)
                        .fill(glyphColor)
                        .frame(width: NotchMetrics.sizeGlyphMinWidth, height: 5)
                    UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 5,
                                           bottomTrailingRadius: 5, topTrailingRadius: 2)
                        .fill(glyphColor)
                        .frame(width: NotchMetrics.sizeGlyphWidth(forVideoWidth: videoSize.width), height: 20)
                }
                .frame(height: 30)
                Text(size.label)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? NotchPalette.accentBright : NotchPalette.primaryText.opacity(0.72))
                Text("\(Int(videoSize.width))×\(Int(videoSize.height))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.38))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? NotchPalette.accent.opacity(0.16) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? NotchPalette.accentSoft.opacity(0.55) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.85))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.4))
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(NotchPalette.accent)
                .scaleEffect(0.8)
                .frame(width: 40)
        }
    }
}
