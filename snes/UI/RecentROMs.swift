//  RecentROMs.swift
//  Lista de ROMs recentes com bookmarks com escopo de segurança (app sandbox).

import Foundation
import Combine

@MainActor
final class RecentROMs: ObservableObject {
    static let shared = RecentROMs()

    struct Entry: Identifiable, Equatable {
        let id: String
        let name: String
        let openedAt: Date
        let bookmark: Data

        /// Título do header vem em caixa alta; para exibir, capitaliza.
        var displayName: String {
            name == name.uppercased() ? name.capitalized : name
        }

        var relativeDescription: String {
            Self.relativeFormatter.localizedString(for: openedAt, relativeTo: Date())
        }

        private static let relativeFormatter: RelativeDateTimeFormatter = {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter
        }()
    }

    @Published private(set) var entries: [Entry] = []

    private let defaultsKey = "notch.recentROMs"
    private let limit = 10

    private init() { load() }

    func remember(url: URL, title: String) {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        let entry = Entry(id: url.path, name: title.isEmpty ? url.lastPathComponent : title,
                          openedAt: Date(), bookmark: bookmark)
        var next = entries.filter { $0.id != entry.id }
        next.insert(entry, at: 0)
        entries = Array(next.prefix(limit))
        save()
    }

    /// Resolve o bookmark. O chamador é dono do `stopAccessingSecurityScopedResource`.
    func resolve(_ entry: Entry) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: entry.bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        return url
    }

    private func save() {
        let raw: [[String: Any]] = entries.map {
            ["id": $0.id, "name": $0.name, "openedAt": $0.openedAt, "bookmark": $0.bookmark]
        }
        UserDefaults.standard.set(raw, forKey: defaultsKey)
    }

    private func load() {
        guard let raw = UserDefaults.standard.array(forKey: defaultsKey) as? [[String: Any]] else { return }
        entries = raw.compactMap { item in
            guard let id = item["id"] as? String,
                  let name = item["name"] as? String,
                  let openedAt = item["openedAt"] as? Date,
                  let bookmark = item["bookmark"] as? Data else { return nil }
            return Entry(id: id, name: name, openedAt: openedAt, bookmark: bookmark)
        }
    }
}
