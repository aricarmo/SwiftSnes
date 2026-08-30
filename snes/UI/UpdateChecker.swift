//  UpdateChecker.swift
//  Consulta a última release no GitHub e avisa quando há versão mais nova que
//  a instalada. Não baixa nada: "Baixar" abre a página da release no navegador.

import AppKit
import Combine

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String
        let url: URL
        /// Primeira linha das notas da release, para o subtítulo.
        let summary: String?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available(Release)
        case failed
    }

    @Published private(set) var state: State = .idle
    /// A engrenagem fica lilás até o usuário abrir os ajustes.
    @Published private(set) var seen = true

    nonisolated static let repo = "aricarmo/SwiftSnes"
    static let interval: TimeInterval = 24 * 60 * 60

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var available: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    private var timer: Timer?
    private var task: Task<Void, Never>?

    private init() {}

    func start() {
        check()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func check() {
        guard state != .checking else { return }
        state = .checking
        task?.cancel()
        task = Task { [weak self] in
            let result = await Self.fetchLatest()
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .failure:
                self.state = .failed
            case .success(let release):
                if Self.isNewer(release.version, than: self.currentVersion) {
                    if self.available != release { self.seen = false }
                    self.state = .available(release)
                } else {
                    self.state = .upToDate(Date())
                }
            }
        }
    }

    func markSeen() {
        seen = true
    }

    func openDownloadPage() {
        guard let release = available else { return }
        NSWorkspace.shared.open(release.url)
    }

    // MARK: - GitHub

    private struct LatestPayload: Decodable {
        let tag_name: String
        let html_url: URL
        let body: String?
    }

    nonisolated private static func fetchLatest() async -> Result<Release, Error> {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NotchSnes", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let payload = try JSONDecoder().decode(LatestPayload.self, from: data)
            let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
            let summary = payload.body?
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*- ").union(.whitespaces)) }
                .first { !$0.isEmpty && !$0.contains("http") }
            return .success(Release(version: version, url: payload.html_url, summary: summary))
        } catch {
            return .failure(error)
        }
    }

    /// Compara "1.2.3" numericamente, componente a componente.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
