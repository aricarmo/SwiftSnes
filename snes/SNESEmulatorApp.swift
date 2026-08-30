//
//  SNESEmulatorApp.swift
//  snes
//
//  Created by Arilson Simplicio on 14/05/25.
//

import SwiftUI

@main
struct SNESEmulatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Nenhuma janela: a interface inteira vive no painel do notch,
        // criado pelo AppDelegate.
        Settings {
            EmptyView()
        }
    }
}
