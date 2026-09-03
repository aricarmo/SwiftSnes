//  CoverStore.swift
//  Capas dos jogos, baixadas sob demanda do servidor de miniaturas do
//  Libretro (as mesmas do RetroArch) e guardadas em disco. A ROM raramente
//  tem o nome exato do catálogo No-Intro, então o casamento é por nome
//  normalizado, com preferência pela edição americana.

import AppKit
import Combine
import CryptoKit

@MainActor
final class CoverStore: ObservableObject {
    static let shared = CoverStore()

    /// Incrementa quando uma capa nova chega: quem desenha observa isto.
    @Published private(set) var version = 0

    private var memory: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var pending: Set<String> = []
    private let fetcher = CoverFetcher()

    private init() {}

    /// Capa em memória; se ainda não há, dispara a busca e devolve nil.
    func cover(for item: GameLibrary.Item) -> NSImage? {
        if let image = memory[item.id] { return image }
        guard !missing.contains(item.id), !pending.contains(item.id) else { return nil }
        pending.insert(item.id)
        let key = item.id
        let stem = item.fileStem
        let title = item.name
        Task { [weak self] in
            let image = await self?.fetcher.cover(key: key, stem: stem, title: title)
            guard let self else { return }
            pending.remove(key)
            if let image {
                memory[key] = image
            } else {
                missing.insert(key)
            }
            version += 1
        }
        return nil
    }
}

/// Parte fora da main actor: rede, disco e o casamento de nomes.
actor CoverFetcher {
    private static let base = URL(string: "https://thumbnails.libretro.com/Nintendo%20-%20Super%20Nintendo%20Entertainment%20System/Named_Boxarts/")!
    private static let indexMaxAge: TimeInterval = 30 * 24 * 3600
    private static let missMaxAge: TimeInterval = 7 * 24 * 3600

    private var index: [String]?
    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("NotchSnes/covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func cover(key: String, stem: String, title: String) async -> NSImage? {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        let file = directory.appendingPathComponent("\(hash).png")
        let miss = directory.appendingPathComponent("\(hash).none")
        if let image = NSImage(contentsOf: file) { return image }
        if let date = try? miss.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(date) < Self.missMaxAge {
            return nil
        }

        guard let names = await loadIndex(),
              let name = Self.bestMatch(stem: stem, title: title, in: names),
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: encoded + ".png", relativeTo: Self.base),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data) else {
            FileManager.default.createFile(atPath: miss.path, contents: Data())
            return nil
        }
        try? data.write(to: file)
        return image
    }

    /// Lista de nomes do catálogo: uma página HTML com um link por arquivo.
    private func loadIndex() async -> [String]? {
        if let index { return index }
        let cache = directory.appendingPathComponent("index.txt")
        if let date = try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(date) < Self.indexMaxAge,
           let text = try? String(contentsOf: cache, encoding: .utf8) {
            index = text.split(separator: "\n").map(String.init)
            return index
        }
        guard let (data, _) = try? await URLSession.shared.data(from: Self.base),
              let html = String(data: data, encoding: .utf8) else { return index }
        var names: [String] = []
        for match in html.matches(of: /href="([^"]+)\.png"/) {
            if let name = String(match.1).removingPercentEncoding { names.append(name) }
        }
        guard !names.isEmpty else { return nil }
        try? names.joined(separator: "\n").write(to: cache, atomically: true, encoding: .utf8)
        index = names
        return names
    }

    // MARK: - Casamento de nomes

    /// Só letras e dígitos, sem região entre parênteses, sem artigos.
    static func normalize(_ s: String) -> String {
        var text = s.lowercased()
        text = text.replacing(/\([^)]*\)|\[[^\]]*\]/, with: " ")
        text = text.replacingOccurrences(of: "&", with: " and ")
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0 != "the" && $0 != "a" }
        return words.joined()
    }

    private static func regionScore(_ name: String) -> Int {
        if name.contains("(USA") || name.contains("(World") { return 3 }
        if name.contains("(Europe") { return 2 }
        if name.contains("(Japan") { return 1 }
        return 0
    }

    static func bestMatch(stem: String, title: String, in names: [String]) -> String? {
        let wanted = [normalize(stem), normalize(title)].filter { $0.count >= 3 }
        guard !wanted.isEmpty else { return nil }
        var exact: [String] = []
        var partial: [String] = []
        for name in names {
            let base = normalize(name)
            if wanted.contains(base) {
                exact.append(name)
            } else if wanted.contains(where: { base.hasPrefix($0) || $0.hasPrefix(base) }) {
                partial.append(name)
            }
        }
        let pool = exact.isEmpty ? partial : exact
        return pool.min { a, b in
            let ra = regionScore(a), rb = regionScore(b)
            if ra != rb { return ra > rb }
            return a.count < b.count
        }
    }
}
