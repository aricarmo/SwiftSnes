//  GlobalHotKey.swift
//  Atalho global via Carbon (não exige permissão de acessibilidade).

import Carbon.HIToolbox
import AppKit

@MainActor
final class GlobalHotKey {
    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private let id: UInt32
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?

    /// `keyCode`/`modifiers` no vocabulário do Carbon (ex.: `kVK_ANSI_P`, `cmdKey | shiftKey`).
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.id = GlobalHotKey.nextID
        GlobalHotKey.nextID += 1

        GlobalHotKey.installHandlerIfNeeded()

        let eventID = EventHotKeyID(signature: OSType(0x534E4553), id: id)  // 'SNES'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, eventID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }

        self.hotKeyRef = ref
        GlobalHotKey.registry[id] = self
    }

    func invalidate() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        GlobalHotKey.registry[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var received = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &received
            )
            guard status == noErr else { return status }
            let id = received.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKey.registry[id]?.action() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
