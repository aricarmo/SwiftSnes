//  GameLibrary.swift
//  Estado da biblioteca (carrossel): jogos recentes primeiro, depois o resto
//  da pasta de ROMs em ordem alfabética; seleção e navegação por teclado,
//  controle e clique.

import Combine
import Foundation

@MainActor
final class GameLibrary: ObservableObject {
    /// Um cartucho no carrossel: veio dos recentes ou da pasta de ROMs.
    struct Item: Identifiable, Equatable {
        enum Source: Equatable {
            case recent(RecentROMs.Entry)
            case file(URL)
        }

        let id: String
        let name: String
        let source: Source

        /// Título do header vem em caixa alta; para exibir, capitaliza.
        var displayName: String {
            name == name.uppercased() ? name.capitalized : name
        }
        var lastPlayed: String? {
            if case .recent(let entry) = source { return entry.relativeDescription }
            return nil
        }
        /// Nome do arquivo sem extensão, com as etiquetas de região: é o que
        /// casa com o catálogo de capas.
        var fileStem: String {
            URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var selectedIndex = 0
    /// Cartucho sendo "encaixado no console": a animação roda e só depois a ROM carrega.
    @Published private(set) var inserting: Item?
    /// Inclinação do cartucho escolhido pelo stick direito (-1...1 em cada eixo).
    @Published private(set) var tilt = CGPoint.zero

    var onOpen: ((Item) -> Void)?

    private var cancellables = Set<AnyCancellable>()
    /// Última máscara do controle: só bordas de subida navegam.
    private var padMask: UInt16 = 0
    private var repeatTimer: Timer?

    static let repeatDelay: TimeInterval = 0.4
    static let repeatInterval: TimeInterval = 0.16
    /// Duração total da animação de encaixe (volta + vir para frente + descer).
    static let insertDuration: TimeInterval = 1.75

    init(recents: RecentROMs, folder: ROMFolder) {
        recents.$entries.combineLatest(folder.$files)
            .sink { [weak self] entries, files in
                guard let self else { return }
                let selectedId = selected?.id
                items = Self.merge(recents: entries, files: files)
                // Abrir um jogo o manda para a frente da lista: volta ao começo.
                // Mudança só na pasta mantém o cartucho escolhido.
                if entries.map(\.id) != self.lastRecentIds {
                    selectedIndex = 0
                } else {
                    selectedIndex = items.firstIndex { $0.id == selectedId } ?? 0
                }
                lastRecentIds = entries.map(\.id)
            }
            .store(in: &cancellables)
    }

    private var lastRecentIds: [String] = []

    /// Recentes na ordem de uso, depois os arquivos da pasta que ainda não
    /// foram jogados, em ordem alfabética.
    ///
    /// O recente guarda o caminho de onde a ROM foi aberta (Downloads, um zip),
    /// que raramente é o da pasta. O mesmo jogo é reconhecido pelo nome do
    /// arquivo ou pelo título sem espaços, região e pontuação: o "Mega Man X
    /// (U) (V1.1).smc" da pasta é o "MEGAMAN X" do header.
    private static func merge(recents: [RecentROMs.Entry], files: [ROMFolder.File]) -> [Item] {
        let items = recents.map { Item(id: $0.id, name: $0.name, source: .recent($0)) }
        var known = Set<String>()
        for item in items {
            known.insert(item.id)
            known.insert(URL(fileURLWithPath: item.id).lastPathComponent.lowercased())
            known.insert(CoverFetcher.normalize(item.name))
            known.insert(CoverFetcher.normalize(item.fileStem))
        }
        let fresh = files.filter { file in
            !known.contains(file.id)
                && !known.contains(file.url.lastPathComponent.lowercased())
                && !known.contains(CoverFetcher.normalize(file.name))
        }
        return items + fresh.map { Item(id: $0.id, name: $0.name, source: .file($0.url)) }
    }

    var selected: Item? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    func select(_ index: Int) {
        guard inserting == nil, items.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
    }

    func move(_ delta: Int) {
        select(min(max(0, selectedIndex + delta), items.count - 1))
    }

    func openSelected() {
        guard inserting == nil, let selected else { return }
        stopRepeat()
        inserting = selected
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.insertDuration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.inserting?.id == selected.id else { return }
                self.onOpen?(selected)
                // Se a ROM não carregou, o carrossel volta ao lugar.
                self.inserting = nil
            }
        }
    }

    // MARK: - Controle

    /// Chamado a cada mudança da máscara do controle enquanto a biblioteca está aberta.
    func padChanged(_ mask: UInt16) {
        let pressed = mask & ~padMask
        padMask = mask
        guard inserting == nil else { return }
        let left = SNESButton.left.mask, right = SNESButton.right.mask
        if pressed & left != 0 { move(-1); startRepeat(-1) }
        if pressed & right != 0 { move(1); startRepeat(1) }
        if mask & (left | right) == 0 { stopRepeat() }
        if pressed & (SNESButton.a.mask | SNESButton.start.mask | SNESButton.b.mask) != 0 {
            openSelected()
        }
    }

    /// Stick direito: zona morta e passo grosso, para não redesenhar a cada
    /// tremida do analógico.
    func setTilt(x: Float, y: Float) {
        func quantize(_ v: Float) -> CGFloat {
            let dead: Float = 0.12
            guard abs(v) > dead else { return 0 }
            let scaled = (abs(v) - dead) / (1 - dead)
            return CGFloat((scaled * 25).rounded() / 25) * (v < 0 ? -1 : 1)
        }
        let next = CGPoint(x: quantize(x), y: quantize(y))
        if next != tilt { tilt = next }
    }

    /// Solta tudo: a biblioteca fechou (jogo carregado) e o timer não pode
    /// continuar mexendo na seleção.
    func padReleased() {
        padMask = 0
        tilt = .zero
        stopRepeat()
    }

    private func startRepeat(_ delta: Int) {
        stopRepeat()
        let timer = Timer(timeInterval: Self.repeatDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.move(delta)
                let repeating = Timer(timeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.move(delta) }
                }
                RunLoop.main.add(repeating, forMode: .common)
                self.repeatTimer = repeating
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}
