//  StateStore.swift
//  Último estado do console por ROM (.nss) em Application Support, ao lado dos
//  .srm. É o que permite reabrir o jogo exatamente onde parou.

import Foundation

struct StateStore {
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directory = support.appendingPathComponent("NotchSnes/states", isDirectory: true)
        }
    }

    func url(forROMHash hash: String) -> URL {
        directory.appendingPathComponent(hash).appendingPathExtension("nss")
    }

    /// Bytes do state e quando foi gravado.
    func load(romHash: String) -> (state: [UInt8], savedAt: Date)? {
        let file = url(forROMHash: romHash)
        guard let data = try? Data(contentsOf: file) else { return nil }
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        return ([UInt8](data), date)
    }

    func save(_ state: [UInt8], romHash: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(state).write(to: url(forROMHash: romHash), options: .atomic)
    }

    func remove(romHash: String) {
        try? FileManager.default.removeItem(at: url(forROMHash: romHash))
    }
}
