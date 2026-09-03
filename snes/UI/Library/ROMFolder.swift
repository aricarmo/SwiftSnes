//  ROMFolder.swift
//  Pasta padrão de ROMs escolhida nos ajustes. O acesso persiste por bookmark
//  com escopo de segurança (app sandbox) e a lista de arquivos alimenta a
//  biblioteca junto com os recentes.

import AppKit
import Combine

@MainActor
final class ROMFolder: ObservableObject {
    static let shared = ROMFolder()

    struct File: Identifiable, Equatable {
        let url: URL
        /// Nome do arquivo sem extensão nem etiquetas de região: "(USA)", "[!]".
        let name: String
        var id: String { url.path }
    }

    @Published private(set) var url: URL?
    @Published private(set) var files: [File] = []

    private let defaultsKey = "notch.romFolderBookmark"
    private var accessing = false
    private static let extensions: Set<String> = ["sfc", "smc", "fig", "swc", "zip"]
    private static let maxFiles = 2000

    private init() {
        restore()
    }

    /// Caminho curto para exibir: "~/Jogos/SNES".
    var displayPath: String? {
        url.map { ($0.path as NSString).abbreviatingWithTildeInPath }
    }

    func set(_ folder: URL) {
        guard let bookmark = try? folder.bookmarkData(options: .withSecurityScope,
                                                       includingResourceValuesForKeys: nil,
                                                       relativeTo: nil) else { return }
        UserDefaults.standard.set(bookmark, forKey: defaultsKey)
        stopAccess()
        url = folder
        accessing = folder.startAccessingSecurityScopedResource()
        rescan()
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        stopAccess()
        url = nil
        files = []
    }

    /// Relê a pasta; só publica se a lista mudou.
    func rescan() {
        guard let url else { return }
        let next = Self.scan(url)
        if next != files { files = next }
    }

    private func restore() {
        guard let bookmark = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                      relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        url = resolved
        accessing = resolved.startAccessingSecurityScopedResource()
        if stale { set(resolved) } else { rescan() }
    }

    private func stopAccess() {
        if accessing, let url { url.stopAccessingSecurityScopedResource() }
        accessing = false
    }

    private static func scan(_ folder: URL) -> [File] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [File] = []
        for case let url as URL in enumerator {
            guard files.count < maxFiles else { break }
            guard extensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files.append(File(url: url, name: cleanName(url.deletingPathExtension().lastPathComponent)))
        }
        return files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "Chrono Trigger (USA) [!]" -> "Chrono Trigger".
    static func cleanName(_ stem: String) -> String {
        let cleaned = stem.replacing(/\s*[\(\[][^\)\]]*[\)\]]/, with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? stem : cleaned
    }
}
