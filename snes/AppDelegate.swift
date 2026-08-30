//
//  AppDelegate.swift
//  snes
//
//  Created by Arilson Simplicio on 14/05/25.
//

import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var viewModel: EmulatorViewModel?
    private var notchController: NotchWindowController?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // App acessório: sem ícone no Dock e sem barra de menus própria.
        NSApp.setActivationPolicy(.accessory)

        let viewModel = EmulatorViewModel()
        let controller = NotchWindowController(viewModel: viewModel)
        self.viewModel = viewModel
        self.notchController = controller
        controller.show()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        viewModel?.stopEmulation()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
