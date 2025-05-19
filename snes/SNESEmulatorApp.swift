//
//  SNESEmulatorApp.swift
//  snes
//
//  Created by Arilson Simplicio on 14/05/25.
//


// main.swift
import SwiftUI

@main
struct SNESEmulatorApp: App {
    var body: some Scene {
        WindowGroup {
            EmulatorView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 600, height: 550)
        .commands {
            // Customiza menus
            CommandGroup(replacing: .newItem) { }
            
            CommandMenu("Emulador") {
                Button("Carregar ROM...") {
                    // Será tratado pela view
                }
                .keyboardShortcut("o")
                
                Divider()
                
                Button("Iniciar/Pausar") {
                    // Será tratado pela view
                }
                .keyboardShortcut("p")
                
                Button("Reset") {
                    // Será tratado pela view
                }
                .keyboardShortcut("r")
            }
        }
    }
}