//  KeyBindings.swift
//  Mapeamento configurável de teclas -> bits do joypad ($4218).

import AppKit
import Combine
import Carbon.HIToolbox

struct SNESButton: Identifiable, Hashable {
    let id: String
    let label: String
    /// Formato: B Y Sel Sta Up Dn Lf Rt A X L R 0 0 0 0
    let mask: UInt16

    static let up     = SNESButton(id: "up",     label: "Cima",      mask: 0x0800)
    static let down   = SNESButton(id: "down",   label: "Baixo",     mask: 0x0400)
    static let left   = SNESButton(id: "left",   label: "Esquerda",  mask: 0x0200)
    static let right  = SNESButton(id: "right",  label: "Direita",   mask: 0x0100)
    static let a      = SNESButton(id: "a",      label: "A",         mask: 0x0080)
    static let b      = SNESButton(id: "b",      label: "B",         mask: 0x8000)
    static let x      = SNESButton(id: "x",      label: "X",         mask: 0x0040)
    static let y      = SNESButton(id: "y",      label: "Y",         mask: 0x4000)
    static let l      = SNESButton(id: "l",      label: "L",         mask: 0x0020)
    static let r      = SNESButton(id: "r",      label: "R",         mask: 0x0010)
    static let start  = SNESButton(id: "start",  label: "Start",     mask: 0x1000)
    static let select = SNESButton(id: "select", label: "Select",    mask: 0x2000)

    static let all: [SNESButton] = [up, down, left, right, a, b, x, y, l, r, start, select]
    /// Ordem exibida no painel de ajustes, em duas colunas.
    static let displayOrder: [SNESButton] = [b, start, a, select, y, l, x, r]
}

@MainActor
final class KeyBindings: ObservableObject {
    static let shared = KeyBindings()

    /// keyCode do macOS -> botão
    @Published private(set) var map: [UInt16: SNESButton] = [:]

    private let defaultsKey = "notch.keyBindings"
    private let defaults = UserDefaults.standard

    private static let factory: [String: UInt16] = [
        "b": 6,       // Z
        "y": 0,       // A
        "select": 49, // Espaço
        "start": 36,  // Return
        "up": 126, "down": 125, "left": 123, "right": 124,
        "a": 7,       // X
        "x": 1,       // S
        "l": 12,      // Q
        "r": 13       // W
    ]

    private init() {
        let stored = defaults.dictionary(forKey: defaultsKey) as? [String: Int]
        let pairs = stored?.compactMapValues { UInt16(exactly: $0) } ?? KeyBindings.factory
        rebuild(from: pairs.isEmpty ? KeyBindings.factory : pairs)
    }

    private func rebuild(from pairs: [String: UInt16]) {
        var next: [UInt16: SNESButton] = [:]
        for button in SNESButton.all {
            if let code = pairs[button.id] {
                next[code] = button
            }
        }
        map = next
    }

    func keyCode(for button: SNESButton) -> UInt16? {
        map.first { $0.value == button }?.key
    }

    func label(for button: SNESButton) -> String {
        guard let code = keyCode(for: button) else { return "nenhuma" }
        return KeyBindings.name(for: code)
    }

    /// Regrava um botão. Uma tecla só pode servir a um botão.
    func bind(_ button: SNESButton, to keyCode: UInt16) {
        var pairs: [String: UInt16] = [:]
        for (code, btn) in map where btn != button && code != keyCode {
            pairs[btn.id] = code
        }
        pairs[button.id] = keyCode
        rebuild(from: pairs)
        defaults.set(pairs.mapValues { Int($0) }, forKey: defaultsKey)
    }

    func restoreDefaults() {
        rebuild(from: KeyBindings.factory)
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Nome curto e legível de um keyCode.
    static func name(for keyCode: UInt16) -> String {
        if let special = specialNames[keyCode] { return special }
        return literal(for: keyCode) ?? "tecla \(keyCode)"
    }

    private static let specialNames: [UInt16: String] = [
        126: "↑", 125: "↓", 123: "←", 124: "→",
        36: "return", 49: "espaço", 48: "tab", 53: "esc",
        51: "delete", 117: "fwd del",
        56: "shift", 59: "control", 58: "option", 55: "command"
    ]

    private static func literal(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
