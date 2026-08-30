import AppKit
//  GamepadInput.swift
//  Controle físico (GameController.framework) -> bits do joypad ($4218).
//  O mapeamento é configurável e persistido, no mesmo molde de KeyBindings.

import Combine
import GameController

/// Elementos de um controle estendido que podem ser mapeados a um botão do SNES.
enum GamepadElement: String, CaseIterable, Codable {
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case menu, options, home
    case leftThumbstickButton, rightThumbstickButton

    /// Rótulo curto em layout Xbox / PlayStation, para quando o controle não
    /// informa o nome do próprio botão.
    var genericLabel: String {
        switch self {
        case .buttonA: return "A / ✕"
        case .buttonB: return "B / ○"
        case .buttonX: return "X / □"
        case .buttonY: return "Y / △"
        case .leftShoulder: return "LB / L1"
        case .rightShoulder: return "RB / R1"
        case .leftTrigger: return "LT / L2"
        case .rightTrigger: return "RT / R2"
        case .menu: return "Menu"
        case .options: return "View"
        case .home: return "Home"
        case .leftThumbstickButton: return "L3"
        case .rightThumbstickButton: return "R3"
        }
    }

    func input(in pad: GCExtendedGamepad) -> GCControllerButtonInput? {
        switch self {
        case .buttonA: return pad.buttonA
        case .buttonB: return pad.buttonB
        case .buttonX: return pad.buttonX
        case .buttonY: return pad.buttonY
        case .leftShoulder: return pad.leftShoulder
        case .rightShoulder: return pad.rightShoulder
        case .leftTrigger: return pad.leftTrigger
        case .rightTrigger: return pad.rightTrigger
        case .menu: return pad.buttonMenu
        case .options: return pad.buttonOptions
        case .home: return pad.buttonHome
        case .leftThumbstickButton: return pad.leftThumbstickButton
        case .rightThumbstickButton: return pad.rightThumbstickButton
        }
    }

    /// Nome que o próprio controle dá ao botão ("Cross", "A"), se souber.
    func label(in controller: GCController?) -> String {
        guard let pad = controller?.extendedGamepad,
              let input = input(in: pad),
              let name = input.localizedName, !name.isEmpty else { return genericLabel }
        return name
    }
}

@MainActor
final class GamepadBindings: ObservableObject {
    static let shared = GamepadBindings()

    /// elemento -> botão
    @Published private(set) var map: [GamepadElement: SNESButton] = [:]

    private let defaultsKey = "notch.gamepadBindings"
    private let defaults = UserDefaults.standard

    /// Layout físico igual ao do SNES: o botão de baixo é B, o da direita é A.
    private static let factory: [String: GamepadElement] = [
        "b": .buttonA, "a": .buttonB, "y": .buttonX, "x": .buttonY,
        "l": .leftShoulder, "r": .rightShoulder,
        "start": .menu, "select": .options,
        // O SNES não tem L2: o gatilho nunca colide com um jogo.
        "rewind": .leftTrigger
    ]

    private init() {
        let stored = (defaults.dictionary(forKey: defaultsKey) as? [String: String])?
            .compactMapValues { GamepadElement(rawValue: $0) }
        var pairs = stored?.isEmpty == false ? stored! : GamepadBindings.factory
        for (id, element) in GamepadBindings.factory where pairs[id] == nil && !pairs.values.contains(element) {
            pairs[id] = element
        }
        rebuild(from: pairs)
    }

    private func rebuild(from pairs: [String: GamepadElement]) {
        var next: [GamepadElement: SNESButton] = [:]
        for button in SNESButton.all {
            if let element = pairs[button.id] { next[element] = button }
        }
        map = next
    }

    func element(for button: SNESButton) -> GamepadElement? {
        map.first { $0.value == button }?.key
    }

    /// Um elemento só pode servir a um botão.
    func bind(_ button: SNESButton, to element: GamepadElement) {
        var pairs: [String: GamepadElement] = [:]
        for (el, btn) in map where btn != button && el != element {
            pairs[btn.id] = el
        }
        pairs[button.id] = element
        rebuild(from: pairs)
        defaults.set(pairs.mapValues(\.rawValue), forKey: defaultsKey)
    }

    func restoreDefaults() {
        rebuild(from: GamepadBindings.factory)
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// Observa o controle conectado e publica a máscara de botões pressionados.
@MainActor
final class GamepadInput: ObservableObject {
    /// Controle em uso (o primeiro com perfil estendido).
    @Published private(set) var controller: GCController?
    /// Máscara no formato de $4218. Não é @Published de propósito: cada evento
    /// do controle redesenharia o painel inteiro e re-mediria o layout, o que
    /// atrasava a entrada. Quem precisa dela na hora recebe por `onPressedChange`.
    private(set) var pressed: UInt16 = 0
    /// Chamado a cada mudança da máscara, ainda no evento do controle.
    var onPressedChange: ((UInt16) -> Void)?
    /// Botão de voltar no tempo acabou de ser pressionado (borda de subida).
    var onRewindPressed: (() -> Void)?
    private var rewindHeld = false
    /// Nível de bateria 0...1, se o controle informar.
    @Published private(set) var batteryLevel: Float?
    /// Mostra "conectado" na pílula recolhida por alguns segundos após parear.
    @Published private(set) var justConnected = false

    /// Regravando: o próximo botão pressionado vira o mapeamento.
    var onCapture: ((GamepadElement) -> Void)?

    private let bindings: GamepadBindings
    private let settings: NotchSettings
    private var observers: [Any] = []
    private var badgeWork: DispatchWorkItem?

    var isConnected: Bool { controller != nil }
    var name: String { controller?.vendorName ?? "Controle" }

    static let stickDeadzone: Float = 0.5
    static let badgeDuration: TimeInterval = 2.0

    init() {
        bindings = .shared
        settings = .shared
        // Fixado com controle, o app devolve o foco ao app anterior de propósito
        // (não rouba o teclado): sem isto o GameController não entrega eventos
        // a um app em segundo plano e o joystick parece morto.
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.attach(note.object as? GCController, announce: true) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.detach(note.object as? GCController) }
        })
        attach(GCController.controllers().first { $0.extendedGamepad != nil }, announce: false)
        GCController.startWirelessControllerDiscovery()
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    private func attach(_ candidate: GCController?, announce: Bool) {
        guard controller == nil, let candidate, let pad = candidate.extendedGamepad else { return }
        controller = candidate
        batteryLevel = candidate.battery?.batteryLevel
        pad.valueChangedHandler = { [weak self] pad, element in
            MainActor.assumeIsolated { self?.handle(pad: pad, changed: element) }
        }
        if announce { flashBadge() }
    }

    private func detach(_ gone: GCController?) {
        guard let gone, gone === controller else { return }
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = nil
        batteryLevel = nil
        pressed = 0
        rewindHeld = false
        // Outro controle ainda ligado assume.
        attach(GCController.controllers().first { $0.extendedGamepad != nil }, announce: false)
    }

    private func flashBadge() {
        justConnected = true
        badgeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.justConnected = false }
        }
        badgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.badgeDuration, execute: work)
    }

    private func handle(pad: GCExtendedGamepad, changed: GCControllerElement) {
        if let onCapture {
            for element in GamepadElement.allCases
            where element.input(in: pad).map({ $0 === changed && $0.isPressed }) == true {
                onCapture(element)
                return
            }
        }
        // Só publica se mudou: @Published notifica mesmo com valor igual.
        let level = controller?.battery?.batteryLevel
        if level != batteryLevel { batteryLevel = level }

        var mask: UInt16 = 0
        var rewindNow = false
        for (element, button) in bindings.map where element.input(in: pad)?.isPressed == true {
            mask |= button.mask
            if button == .rewind { rewindNow = true }
        }
        if rewindNow != rewindHeld {
            rewindHeld = rewindNow
            if rewindNow { onRewindPressed?() }
        }
        mask |= Self.directionMask(pad.dpad)
        if settings.analogAsDpad {
            mask |= Self.directionMask(pad.leftThumbstick)
        }
        if mask != pressed {
            pressed = mask
            onPressedChange?(mask)
        }
    }

    private static func directionMask(_ pad: GCControllerDirectionPad) -> UInt16 {
        var mask: UInt16 = 0
        if pad.up.value > stickDeadzone { mask |= SNESButton.up.mask }
        if pad.down.value > stickDeadzone { mask |= SNESButton.down.mask }
        if pad.left.value > stickDeadzone { mask |= SNESButton.left.mask }
        if pad.right.value > stickDeadzone { mask |= SNESButton.right.mask }
        return mask
    }
}
