//  LibraryBody.swift
//  Corpo do painel sem ROM e com jogos recentes: carrossel 3D de cartuchos,
//  nome do escolhido e dicas de navegação.

import SwiftUI

struct LibraryBody: View {
    @ObservedObject var vm: EmulatorViewModel
    @ObservedObject var library: GameLibrary
    @ObservedObject var gamepad: GamepadInput
    @ObservedObject var updater: UpdateChecker
    @ObservedObject private var covers = CoverStore.shared
    @ObservedObject private var folder = ROMFolder.shared

    let bodyWidth: CGFloat

    private var contentWidth: CGFloat { bodyWidth - NotchMetrics.contentPadding * 2 }

    var body: some View {
        VStack(spacing: 8) {
            if let release = updater.available {
                UpdateAvailableRow(version: release.version, action: updater.install)
                    .padding(.top, 4)
            }

            CartridgeCarouselView(entries: library.items,
                                  selectedIndex: library.selectedIndex,
                                  insertingId: library.inserting?.id,
                                  tilt: library.tilt,
                                  coverVersion: covers.version,
                                  cover: { covers.cover(for: $0) },
                                  onPick: { index in
                                      if index == library.selectedIndex { library.openSelected() } else { library.select(index) }
                                  },
                                  onStep: library.move)
                // A cena vai até a linha do rodapé; nome e pontos ficam por
                // cima dela, nas mesmas alturas de antes.
                .frame(width: contentWidth, height: NotchMetrics.libraryCarouselHeight + NotchMetrics.librarySlotHeight)
                .padding(.bottom, -8)
                .overlay(alignment: .bottom) { selectedRow }

            footer

            if let error = vm.errorText {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchPalette.error)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, NotchMetrics.contentPadding)
        .padding(.bottom, NotchMetrics.contentPadding)
        .frame(width: bodyWidth)
        // A pasta pode ter ganhado arquivos desde a última vez.
        .onAppear(perform: folder.rescan)
    }

    private var selectedRow: some View {
        VStack(spacing: 5) {
            if let entry = library.inserting ?? library.selected {
                Button(action: library.openSelected) {
                    HStack(spacing: 8) {
                        Text(entry.displayName)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                            .foregroundStyle(NotchPalette.primaryText.opacity(0.92))
                        if let lastPlayed = entry.lastPlayed {
                            Text(lastPlayed)
                                .font(.system(size: 9.5))
                                .foregroundStyle(NotchPalette.primaryText.opacity(0.4))
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 26)
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
                .frame(maxWidth: contentWidth - 40)
            }
            PageDots(count: library.items.count, selected: library.selectedIndex)
        }
        // Encaixando: só o cartucho em cena.
        .opacity(library.inserting == nil ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: library.inserting == nil)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if gamepad.isConnected {
                HintKey("◀ ▶", "browse")
                HintKey("A", "play")
            } else {
                HintKey("← →", "browse")
                HintKey("↩", "play")
            }
            Spacer()
            Button(action: vm.showFileDialog) {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 9.5))
                    Text("Open file…")
                        .font(.system(size: 10.5))
                }
                .foregroundStyle(NotchPalette.primaryText.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { NotchPalette.divider.frame(height: 1) }
    }
}

private struct PageDots: View {
    let count: Int
    let selected: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<max(count, 0), id: \.self) { i in
                Capsule()
                    .fill(i == selected ? NotchPalette.accentSoft : Color.white.opacity(0.22))
                    .frame(width: i == selected ? 14 : 4, height: 4)
            }
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.25), value: selected)
    }
}

private struct HintKey: View {
    let key: String
    let label: LocalizedStringKey

    init(_ key: String, _ label: LocalizedStringKey) {
        self.key = key
        self.label = label
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(NotchPalette.primaryText.opacity(0.6))
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(NotchPalette.primaryText.opacity(0.35))
        }
    }
}
