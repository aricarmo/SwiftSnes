//  EmptyDropBody.swift
//  Corpo do painel sem ROM nem recentes: área de drop e erro de carregamento.
//  Com recentes, o painel mostra a `LibraryBody`.

import SwiftUI

struct EmptyDropBody: View {
    @ObservedObject var vm: EmulatorViewModel
    @ObservedObject var presenter: NotchPresenter
    @ObservedObject var updater: UpdateChecker

    let panelWidth: CGFloat

    var body: some View {
        VStack(spacing: 12) {
            if let release = updater.available {
                UpdateAvailableRow(version: release.version, action: updater.openDownloadPage)
            }

            DropZone(action: vm.showFileDialog)

            Button(action: vm.showFolderDialog) {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NotchPalette.accentSoft)
                    Text("Escolher a pasta das suas ROMs…")
                        .font(.system(size: 12))
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.85))
                    Spacer()
                    Text("vira a biblioteca")
                        .font(.system(size: 9.5))
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.35))
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
            }
            .buttonStyle(.plain)

            HStack {
                Text("Ou entre na sessão de alguém")
                    .font(.system(size: 11))
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.5))
                Spacer()
                JoinSessionRow(online: vm.online)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.055))
            )

            if let error = vm.errorText {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchPalette.error)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, NotchMetrics.contentPadding)
        .padding(.bottom, NotchMetrics.contentPadding)
        .frame(width: panelWidth)
    }
}

struct UpdateAvailableRow: View {
    let version: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotchPalette.accentSoft)
                Text("NotchSnes \(version) disponível")
                    .font(.system(size: 12))
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.9))
                Spacer()
                Text("Baixar")
                    .font(.system(size: 11))
                    .foregroundStyle(NotchPalette.accentBright)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(NotchPalette.accent.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(NotchPalette.accentSoft.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct DropZone: View {
    let action: () -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(NotchPalette.accent.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(NotchPalette.accentSoft.opacity(0.38))
            )
            .overlay(
                VStack(spacing: 9) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(NotchPalette.accentSoft)
                    Text("Arraste uma ROM aqui")
                        .font(.system(size: 12.5))
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.78))
                    Text(".SFC  .SMC  .FIG")
                        .font(.system(size: 10))
                        .kerning(0.6)
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.38))
                }
            )
            .frame(height: NotchMetrics.emptyDropHeight)
            .onTapGesture(perform: action)
    }
}

/// Rótulo de seção em caixa alta, usado no vazio e nos ajustes.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 9.5))
            .kerning(1)
            .foregroundStyle(NotchPalette.primaryText.opacity(0.33))
    }
}
