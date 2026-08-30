//  SRAMStore.swift
//  Persistência da SRAM do cartucho (.srm) em Application Support, indexada
//  pelo hash da ROM — o mesmo jogo em arquivos diferentes compartilha o save.

import Foundation

struct SRAMStore {
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directory = support.appendingPathComponent("NotchSnes/saves", isDirectory: true)
        }
    }

    func url(forROMHash hash: String) -> URL {
        directory.appendingPathComponent(hash).appendingPathExtension("srm")
    }

    func load(romHash: String) -> [UInt8]? {
        guard let data = try? Data(contentsOf: url(forROMHash: romHash)) else { return nil }
        return [UInt8](data)
    }

    func save(_ sram: [UInt8], romHash: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(sram).write(to: url(forROMHash: romHash), options: .atomic)
    }
}
