//  UpdateChecker.swift
//  Fachada do Sparkle para o painel: espelha o ciclo de verificação num
//  `State` observável e dispara o fluxo padrão (prompt → download → "Instalar e
//  reiniciar"). O feed é o docs/appcast.xml publicado no GitHub Pages; a
//  instalação roda no XPC Installer do Sparkle porque o app é sandboxed.

import AppKit
import Combine
import Sparkle

@MainActor
final class UpdateChecker: NSObject, ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String
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

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var available: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: self)
    }

    /// Liga o Sparkle: ele mesmo checa no lançamento e a cada 24h
    /// (SUEnableAutomaticChecks/SUScheduledCheckInterval no Info.plist).
    func start() {
        // Builds direto do Xcode ficam com o CURRENT_PROJECT_VERSION=1 do
        // projeto; qualquer release (build = git rev-list --count) seria "mais
        // nova" e o prompt apareceria a cada lançamento durante o desenvolvimento.
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard build != "1" || ProcessInfo.processInfo.environment["NOTCHSNES_APPCAST"] != nil else { return }
        controller.startUpdater()
    }

    /// Verificação pedida pelo usuário: mostra o prompt do Sparkle com o
    /// resultado, seja "Instalar" ou "você já está na versão mais recente".
    func check() {
        controller.checkForUpdates(nil)
    }

    func markSeen() {
        seen = true
    }

    /// Reabre o prompt do Sparkle já com a atualização encontrada.
    func install() {
        controller.checkForUpdates(nil)
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateChecker: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        // NOTCHSNES_APPCAST=http://localhost:8765/appcast.xml permite testar o
        // fluxo com um feed local (file:// não passa pelo sandbox).
        ProcessInfo.processInfo.environment["NOTCHSNES_APPCAST"]
    }

    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        MainActor.assumeIsolated { state = .checking }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let release = Release(version: item.displayVersionString, summary: Self.summary(of: item))
        MainActor.assumeIsolated {
            if available != release { seen = false }
            state = .available(release)
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        MainActor.assumeIsolated { state = .upToDate(Date()) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        MainActor.assumeIsolated {
            guard let error = error as NSError? else { return }
            switch error.code {
            case Int(Sparkle.SUError.noUpdateError.rawValue),
                 Int(Sparkle.SUError.installationCanceledError.rawValue),
                 Int(Sparkle.SUError.installationAuthorizeLaterError.rawValue):
                break
            default:
                if error.domain == SUSparkleErrorDomain, available == nil { state = .failed }
            }
        }
    }

    /// Primeira linha de texto das notas (markdown/HTML do appcast → texto).
    nonisolated private static func summary(of item: SUAppcastItem) -> String? {
        guard let html = item.itemDescription else { return nil }
        let text = html.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*- ").union(.whitespaces)) }
            .first { !$0.isEmpty && !$0.contains("http") }
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdateChecker: SPUStandardUserDriverDelegate {
    /// Num app sem Dock o Sparkle adiaria o alerta das checagens agendadas até
    /// o app "voltar ao foco", o que nunca acontece com um acessório. Com isto
    /// ele mostra o prompt na hora, e a gente traz o app para a frente.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        // O Sparkle cria a janela logo depois deste callback; no ciclo seguinte
        // ela já existe e dá para trazê-la à frente mesmo sem o app ativo.
        DispatchQueue.main.async {
            NSApp.activate()
            for window in NSApp.windows where !(window is NSPanel) && window.isVisible {
                window.orderFrontRegardless()
            }
        }
    }
}
