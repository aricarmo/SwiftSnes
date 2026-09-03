//  Log.swift
//  Loggers por subsistema. `os.Logger` custa zero quando a categoria está
//  desligada e aparece no Console.app filtrado por subsystem.

import os

enum Log {
    private static let subsystem = "com.ari.NotchSnes"

    static let cart = Logger(subsystem: subsystem, category: "cart")
    static let cpu = Logger(subsystem: subsystem, category: "cpu")
    static let apu = Logger(subsystem: subsystem, category: "apu")
    static let dsp = Logger(subsystem: subsystem, category: "cart-dsp")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let emulator = Logger(subsystem: subsystem, category: "emulator")
    static let saves = Logger(subsystem: subsystem, category: "saves")
    static let online = Logger(subsystem: subsystem, category: "online")
}
