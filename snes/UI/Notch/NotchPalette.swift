//  NotchPalette.swift
//  Cores do painel. Ele é sempre preto sobre o notch: não segue o tema do sistema.

import SwiftUI

enum NotchPalette {
    static let panel = Color.black
    static let accent = Color(red: 0.486, green: 0.361, blue: 1.0)     // #7c5cff
    static let accentSoft = Color(red: 0.718, green: 0.608, blue: 1.0) // #b79bff
    static let accentBright = Color(red: 0.788, green: 0.710, blue: 1.0)
    static let running = Color(red: 0.294, green: 0.871, blue: 0.502)  // #4ade80
    static let primaryText = Color(red: 0.961, green: 0.961, blue: 0.969)
    static let error = Color(red: 1, green: 0.45, blue: 0.42)
    static let divider = Color.white.opacity(0.08)
}
