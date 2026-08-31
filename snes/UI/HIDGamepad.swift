//  HIDGamepad.swift
//  Controles HID genéricos (clones USB "2 eixos / 11 botões" etc.) que o
//  GameController.framework não reconhece. Lê IOHIDManager direto e entrega
//  botões por índice + direções; o GamepadInput funde isso com o resto.

import Foundation
import GameController
import IOKit.hid

@MainActor
final class HIDGamepad {
    /// Nome do controle ativo, nil se nenhum controle genérico está plugado.
    private(set) var name: String?
    /// Índices (1-based, usage page Button) pressionados agora.
    private(set) var buttonsDown: Set<Int> = []
    /// Direções (eixos X/Y + hat) já no formato de $4218.
    private(set) var directionMask: UInt16 = 0

    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    /// Qualquer mudança de botão/direção (já refletida nas propriedades).
    var onChange: (() -> Void)?
    /// Borda de subida de um botão, para o fluxo de regravação.
    var onButtonDown: ((Int) -> Void)?

    private var manager: IOHIDManager?
    private var devices: [IOHIDDevice] = []
    private var active: IOHIDDevice?
    private var axisMask: UInt16 = 0
    private var hatMask: UInt16 = 0

    init() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            MainActor.assumeIsolated {
                Unmanaged<HIDGamepad>.fromOpaque(context!).takeUnretainedValue().deviceMatched(device)
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            MainActor.assumeIsolated {
                Unmanaged<HIDGamepad>.fromOpaque(context!).takeUnretainedValue().deviceRemoved(device)
            }
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            MainActor.assumeIsolated {
                Unmanaged<HIDGamepad>.fromOpaque(context!).takeUnretainedValue().valueChanged(value)
            }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    deinit {
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        // Nota: GCController.supportsHIDDevice mente para clones genéricos
        // (diz que adota mas o controle nunca aparece em controllers()), então
        // a deduplicação com o GameController.framework é feita no GamepadInput:
        // enquanto houver um GCController conectado, os eventos HID são ignorados.
        guard !devices.contains(where: { $0 === device }) else { return }
        devices.append(device)
        if active == nil { activate(device) }
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        devices.removeAll { $0 === device }
        guard device === active else { return }
        active = nil
        resetState()
        if let next = devices.first {
            activate(next)
        } else {
            name = nil
            onDisconnect?()
        }
    }

    private func activate(_ device: IOHIDDevice) {
        active = device
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        // Clones costumam vir com espaços duplicados ("2Axes 11Keys Game  Pad").
        name = product?
            .split(separator: " ")
            .joined(separator: " ")
        if name?.isEmpty != false { name = "Controle USB" }
        onConnect?()
    }

    private func resetState() {
        buttonsDown = []
        axisMask = 0
        hatMask = 0
        directionMask = 0
    }

    private func valueChanged(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetDevice(element) === active else { return }
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        switch usagePage {
        case UInt32(kHIDPage_Button):
            let index = Int(usage)
            let wasDown = buttonsDown.contains(index)
            let isDown = intValue != 0
            guard wasDown != isDown else { return }
            if isDown {
                buttonsDown.insert(index)
                onButtonDown?(index)
            } else {
                buttonsDown.remove(index)
            }
        case UInt32(kHIDPage_GenericDesktop):
            switch usage {
            case UInt32(kHIDUsage_GD_X), UInt32(kHIDUsage_GD_Y):
                updateAxis(element, usage: usage, value: intValue)
            case UInt32(kHIDUsage_GD_Hatswitch):
                updateHat(element, value: intValue)
            default:
                return
            }
        default:
            return
        }
        let mask = axisMask | hatMask
        if mask != directionMask { directionMask = mask }
        onChange?()
    }

    private func updateAxis(_ element: IOHIDElement, usage: UInt32, value: Int) {
        let min = IOHIDElementGetLogicalMin(element)
        let max = IOHIDElementGetLogicalMax(element)
        guard max > min else { return }
        let normalized = Float(value - min) / Float(max - min)
        let low = normalized < 0.30
        let high = normalized > 0.70
        if usage == UInt32(kHIDUsage_GD_X) {
            axisMask &= ~(SNESButton.left.mask | SNESButton.right.mask)
            if low { axisMask |= SNESButton.left.mask }
            if high { axisMask |= SNESButton.right.mask }
        } else {
            axisMask &= ~(SNESButton.up.mask | SNESButton.down.mask)
            if low { axisMask |= SNESButton.up.mask }
            if high { axisMask |= SNESButton.down.mask }
        }
    }

    private func updateHat(_ element: IOHIDElement, value: Int) {
        let min = IOHIDElementGetLogicalMin(element)
        let max = IOHIDElementGetLogicalMax(element)
        let positions = max - min + 1
        let step = value - min
        hatMask = 0
        // Fora da faixa lógica = neutro. 8 posições no sentido horário a partir
        // de "cima"; hats de 4 posições só têm os pontos cardeais.
        guard step >= 0, step < positions else { return }
        if positions >= 8 {
            switch step {
            case 0: hatMask = SNESButton.up.mask
            case 1: hatMask = SNESButton.up.mask | SNESButton.right.mask
            case 2: hatMask = SNESButton.right.mask
            case 3: hatMask = SNESButton.down.mask | SNESButton.right.mask
            case 4: hatMask = SNESButton.down.mask
            case 5: hatMask = SNESButton.down.mask | SNESButton.left.mask
            case 6: hatMask = SNESButton.left.mask
            case 7: hatMask = SNESButton.up.mask | SNESButton.left.mask
            default: break
            }
        } else {
            switch step {
            case 0: hatMask = SNESButton.up.mask
            case 1: hatMask = SNESButton.right.mask
            case 2: hatMask = SNESButton.down.mask
            case 3: hatMask = SNESButton.left.mask
            default: break
            }
        }
    }
}
