//  SessionStrip.swift
//  Faixa da sessão online abaixo da tela: código da sala, quem está em cada
//  controle, espectadores e as ações do anfitrião ou do convidado.

import AppKit
import SwiftUI

struct SessionStrip: View {
    @ObservedObject var online: OnlineSession
    let width: CGFloat

    @State private var copied = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel(online.isHosting ? "SUA SESSÃO" : "SESSÃO DE \(hostName.uppercased())")
                if let room = online.room {
                    CodeBadge(code: room.code, copied: copied, onCopy: { copy(room.code) })
                }
                Spacer(minLength: 0)
                if let notice = online.notice {
                    Text(notice)
                        .font(.system(size: 10.5))
                        .foregroundStyle(NotchPalette.accentBright)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                if online.isHosting, let room = online.room {
                    StripButton(text: room.locked ? "Trancado" : "Só assistir",
                                prominent: room.locked,
                                action: { online.setLocked(!room.locked) })
                    StripButton(text: "Encerrar", prominent: false, action: online.stopHosting)
                } else {
                    StripButton(text: "Sair", prominent: false, action: online.leave)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: online.notice)

            if let room = online.room {
                let gap: CGFloat = 6
                let slotWidth = ((width - 20 - gap * CGFloat(RoomState.slotCount - 1)) / CGFloat(RoomState.slotCount)).rounded(.down)
                HStack(spacing: gap) {
                    ForEach(0..<RoomState.slotCount, id: \.self) { slot in
                        SlotCard(slot: slot, participant: room.slots[slot],
                                 isMe: room.slots[slot]?.id == online.myId,
                                 isHost: online.isHosting,
                                 canTake: canTake(slot, in: room),
                                 onTake: { online.takeSlot(slot) },
                                 onRelease: online.releaseSlot,
                                 onKick: { id in online.remove(id) })
                        .frame(width: slotWidth)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "eye")
                        .font(.system(size: 9.5))
                    Text(spectatorsText(room))
                        .font(.system(size: 10))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if room.locked && !online.isHosting {
                        Text("O anfitrião trancou os controles")
                            .font(.system(size: 10))
                    }
                }
                .foregroundStyle(NotchPalette.primaryText.opacity(0.45))
            }
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

    private var hostName: String { online.room?.hostName ?? "" }

    private func canTake(_ slot: Int, in room: RoomState) -> Bool {
        !online.isHosting && slot > 0 && room.slots[slot] == nil && !room.locked && online.mySlot == nil
    }

    private func spectatorsText(_ room: RoomState) -> String {
        let names = room.spectators.map { $0.id == online.myId ? "você" : $0.name }
        switch names.count {
        case 0: return "Ninguém assistindo"
        case 1...3: return "Assistindo: " + names.joined(separator: ", ")
        default: return "\(names.count) assistindo"
        }
    }

    private func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SessionCode.display(code), forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// Código da sala em monoespaçado, clicável para copiar.
private struct CodeBadge: View {
    let code: String
    let copied: Bool
    let onCopy: () -> Void

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 5) {
                Text(SessionCode.display(code))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .kerning(1)
                    .foregroundStyle(NotchPalette.accentBright)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.5))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.35))
            )
        }
        .buttonStyle(.plain)
        .help("Copiar código")
    }
}

/// Um controle do SNES: quem está nele, latência, e a ação disponível.
private struct SlotCard: View {
    let slot: Int
    let participant: Participant?
    let isMe: Bool
    let isHost: Bool
    let canTake: Bool
    let onTake: () -> Void
    let onRelease: () -> Void
    let onKick: (UUID) -> Void

    @State private var hovering = false

    private var filled: Bool { participant != nil }

    var body: some View {
        HStack(spacing: 6) {
            Text("P\(slot + 1)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(filled ? NotchPalette.accentBright : NotchPalette.primaryText.opacity(0.3))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(filled ? NotchPalette.accent.opacity(0.3) : Color.white.opacity(0.05))
                )
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 11, weight: isMe ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(NotchPalette.primaryText.opacity(filled ? 0.9 : 0.4))
                if let detail {
                    Text(detail)
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.4))
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 7)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isMe ? NotchPalette.accent.opacity(0.16) : Color.white.opacity(filled ? 0.06 : 0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isMe ? NotchPalette.accentSoft.opacity(0.55)
                              : filled ? .clear : Color.white.opacity(0.1),
                              style: StrokeStyle(lineWidth: 1, dash: filled ? [] : [3, 3]))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if canTake { onTake() } }
    }

    private var label: String {
        if let participant { return isMe ? "Você" : participant.name }
        return canTake ? "Pegar" : "Livre"
    }

    private var detail: String? {
        guard let participant else { return nil }
        if slot == 0 { return "anfitrião" }
        return participant.latencyMs.map { "\($0) ms" }
    }

    @ViewBuilder
    private var trailing: some View {
        if let participant, slot > 0 {
            if isMe {
                Button(action: onRelease) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.55))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Soltar o controle")
            } else if isHost, hovering {
                Button(action: { onKick(participant.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.55))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Remover da sessão")
            }
        } else if canTake {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(NotchPalette.accentSoft)
        }
    }
}

struct StripButton: View {
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

/// Campo de código + "Entrar": aparece na biblioteca e no painel vazio.
struct JoinSessionRow: View {
    @ObservedObject var online: OnlineSession
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 11))
                .foregroundStyle(NotchPalette.accentSoft)
            if online.isJoining {
                Text("Procurando \(SessionCode.display(joiningCode))…")
                    .font(.system(size: 11))
                    .foregroundStyle(NotchPalette.primaryText.opacity(0.7))
                    .lineLimit(1)
                StripButton(text: "Cancelar", prominent: false, action: online.leave)
            } else {
                TextField("Código", text: Binding(
                    get: { SessionCode.display(online.joinCode) },
                    set: { online.joinCode = SessionCode.normalize($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(NotchPalette.primaryText)
                .focused($focused)
                .frame(width: 74)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(focused ? 0.1 : 0.06))
                )
                .onSubmit { online.join(code: online.joinCode) }
                StripButton(text: "Entrar", prominent: SessionCode.isComplete(online.joinCode),
                            action: { online.join(code: online.joinCode) })
                if let error = online.error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(NotchPalette.primaryText.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var joiningCode: String {
        if case .joining(let code) = online.mode { return code }
        return online.joinCode
    }
}
