//  EmptyDropBody.swift
//  Corpo do painel sem ROM: área de drop, recentes e erro de carregamento.

import SwiftUI

struct EmptyDropBody: View {
    @ObservedObject var vm: EmulatorViewModel
    @ObservedObject var recents: RecentROMs
    @ObservedObject var updater: UpdateChecker

    let panelWidth: CGFloat

    var body: some View {
        VStack(spacing: 12) {
            if let release = updater.available {
                UpdateAvailableRow(version: release.version, action: updater.openDownloadPage)
            }

            DropZone(action: vm.showFileDialog)

            if !recents.entries.isEmpty {
                RecentROMsList(entries: recents.entries, onOpen: vm.loadRecent)
            }

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

private struct UpdateAvailableRow: View {
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

private struct RecentROMsList: View {
    let entries: [RecentROMs.Entry]
    let onOpen: (RecentROMs.Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("RECENTES")
            ForEach(entries) { entry in
                Button {
                    onOpen(entry)
                } label: {
                    HStack {
                        Text(entry.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .foregroundStyle(NotchPalette.primaryText.opacity(0.85))
                        Spacer()
                        Text(entry.relativeDescription)
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
            }
        }
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
