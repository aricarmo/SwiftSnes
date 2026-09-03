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
    @ObservedObject var updater: UpdateChecker
    @ObservedObject private var folder = ROMFolder.shared

    let panelWidth: CGFloat
    let onChooseFolder: () -> Void
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

            SettingToggleRow(title: "Efeito TV antiga",
                             detail: "Simula tela de tubo: scanlines, curvatura e fósforo",
                             isOn: Binding(get: { settings.retroEffectEnabled },
                                           set: { settings.retroEffectEnabled = $0 }))
            if settings.retroEffectEnabled {
                HStack(spacing: 4) {
                    ForEach(ScreenFilter.allCases.filter { $0 != .clean }) { mode in
                        FilterChip(label: mode.label,
                                   isSelected: settings.screenFilter == mode,
                                   onSelect: { settings.screenFilter = mode })
                    }
                }
                Text(settings.screenFilter.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.4))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(NotchPalette.divider)
            SectionLabel("JOGOS")
            ROMFolderRow(folder: folder, onChoose: onChooseFolder, onClear: folder.clear)

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

            Divider().overlay(NotchPalette.divider)
            SectionLabel("ATUALIZAÇÃO")
            UpdateStatusRow(updater: updater)

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
        .onAppear {
            if gamepad.isConnected { source = .gamepad }
            updater.markSeen()
        }
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

/// Pasta padrão de ROMs: caminho atual, escolher e remover.
private struct ROMFolderRow: View {
    @ObservedObject var folder: ROMFolder
    let onChoose: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(folder.url != nil ? NotchPalette.accentSoft : Color.white.opacity(0.3))
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.displayPath ?? "Nenhuma pasta de ROMs")
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(NotchPalette.primaryText.opacity(folder.url != nil ? 0.85 : 0.45))
                Text(folder.url != nil
                     ? "\(folder.files.count) jogos · recentes primeiro, depois A–Z"
                     : "Os jogos dela entram na biblioteca")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.35))
            }
            Spacer(minLength: 6)
            Button(folder.url == nil ? "Escolher…" : "Trocar…", action: onChoose)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(NotchPalette.accentBright)
            if folder.url != nil {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(folder.url != nil ? Color.white.opacity(0.05) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(folder.url != nil ? .clear : Color.white.opacity(0.12),
                              style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
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
                        .font(.system(size: 10))
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.38))
                }
                Circle()
                    .fill(NotchPalette.running)
                    .frame(width: 6, height: 6)
                    .shadow(color: NotchPalette.running.opacity(0.7), radius: 3)
                Text("conectado")
                    .font(.system(size: 10))
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
            .font(.system(size: 10))
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
                    .font(.system(size: 9))
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

/// Botão de filtro retro da tela, no estilo dos chips do painel.
private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Text(label)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .foregroundStyle(isSelected ? NotchPalette.accentBright
                                 : NotchPalette.primaryText.opacity(0.55))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? NotchPalette.accent.opacity(0.22) : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? NotchPalette.accentSoft.opacity(0.55) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct UpdateStatusRow: View {
    @ObservedObject var updater: UpdateChecker

    private var detail: (text: String, color: Color) {
        switch updater.state {
        case .idle:
            return ("Ainda não verificado", NotchPalette.primaryText.opacity(0.4))
        case .checking:
            return ("Verificando…", NotchPalette.primaryText.opacity(0.4))
        case .upToDate(let date):
            let ago = RelativeDateTimeFormatter()
            ago.locale = Locale(identifier: "pt_BR")
            ago.unitsStyle = .short
            return ("Você está na versão mais recente · \(ago.localizedString(for: date, relativeTo: Date()))",
                    NotchPalette.primaryText.opacity(0.4))
        case .available(let release):
            var text = "Nova versão \(release.version)"
            if let summary = release.summary { text += " · \(summary)" }
            return (text, NotchPalette.accentBright)
        case .failed:
            return ("Não foi possível verificar", NotchPalette.error)
        }
    }

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("NotchSnes")
                        .font(.system(size: 12))
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.85))
                    Text("v\(updater.currentVersion)")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.38))
                }
                Text(detail.text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(detail.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            switch updater.state {
            case .checking:
                ProgressView()
                    .controlSize(.small)
                    .tint(NotchPalette.primaryText.opacity(0.5))
            case .available(let release):
                Button(action: updater.openDownloadPage) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Baixar \(release.version)")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(NotchPalette.accentBright)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(NotchPalette.accent.opacity(0.22))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(NotchPalette.accentSoft.opacity(0.55), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            default:
                Button("Verificar", action: updater.check)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchPalette.accentSoft)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
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
