import Combine
import Foundation

/// Main-actor presentation state over the one immutable product-knowledge authority.
///
/// A missing or invalid corpus is an explicit unavailable state. There is intentionally no second
/// compiled-string fallback: two authorities would let the reader and agent answer differently.
@MainActor
final class HelpLibrary: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case ready
        case unavailable
    }

    enum SearchState: Equatable {
        case idle
        case searching
        case results
        case empty
        case failed
    }

    enum ArticleState: Equatable {
        case idle
        case loading(String)
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state: LoadState = .loading
    @Published private(set) var sections: [MechanicianHelpSection] = []
    @Published private(set) var guides: [MechanicianHelpGuide] = []
    @Published private(set) var searchHits: [MechanicianHelpSearchHit] = []
    @Published private(set) var selectedArticle: MechanicianHelpArticle?
    @Published private(set) var selectedMatch: MechanicianHelpSearchHit?
    @Published private(set) var searchState: SearchState = .idle
    @Published private(set) var articleState: ArticleState = .idle

    private(set) var metadata: MechanicianHelpMetadata?
    private var store: MechanicianHelpStore?
    private var loadTask: Task<Void, Never>?
    private var articleTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var articleRequests = HelpRequestGeneration()
    private var searchRequests = HelpRequestGeneration()
    private var pendingSearch: PendingSearch?

    private struct PendingSearch: Equatable {
        let text: String
        let includeHistory: Bool
        let generation: Int
    }

    init(
        resourceURL: URL? = Bundle.main.resourceURL,
        expectedBuild: MechanicianHelpBuildIdentity? = MechanicianHelpBuildIdentity.current()
    ) {
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let opened = try await Task.detached(priority: .userInitiated) {
                    try MechanicianHelpStore.openBundled(
                        resourceURL: resourceURL,
                        expectedBuild: expectedBuild)
                }.value
                try await self.finishOpening(opened)
            } catch {
                guard !Task.isCancelled else { return }
                self.markUnavailable()
            }
        }
    }

    init(store: MechanicianHelpStore) {
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.finishOpening(store)
            } catch {
                guard !Task.isCancelled else { return }
                self.markUnavailable()
            }
        }
    }

    deinit {
        loadTask?.cancel()
        articleTask?.cancel()
        searchTask?.cancel()
    }

    var firstArticleID: String? {
        sections.lazy.flatMap(\.articles).first?.id
    }

    var isSearching: Bool {
        searchState == .searching
    }

    func articleSummary(id: String) -> MechanicianHelpArticleSummary? {
        sections.lazy.flatMap(\.articles).first { $0.id == id }
    }

    func searchHit(id: String) -> MechanicianHelpSearchHit? {
        searchHits.first { $0.id == id }
    }

    func loadArticle(id: String, matched: MechanicianHelpSearchHit? = nil) {
        guard let store else {
            clearArticleSelection()
            articleState = .failed(id)
            return
        }
        let generation = articleRequests.advance()
        articleTask?.cancel()
        selectedArticle = nil
        selectedMatch = nil
        articleState = .loading(id)
        articleTask = Task { [weak self] in
            do {
                guard let article = try await store.article(id: id, includeHistory: true) else {
                    guard !Task.isCancelled,
                          let self,
                          self.articleRequests.accepts(generation) else { return }
                    self.articleState = .failed(id)
                    return
                }
                guard !Task.isCancelled,
                      let self,
                      self.articleRequests.accepts(generation) else { return }
                self.selectedArticle = article
                self.selectedMatch = matched
                self.articleState = .ready(id)
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.articleRequests.accepts(generation) else { return }
                self.selectedArticle = nil
                self.selectedMatch = nil
                self.articleState = .failed(id)
            }
        }
    }

    func clearArticleSelection() {
        _ = articleRequests.advance()
        articleTask?.cancel()
        articleTask = nil
        selectedArticle = nil
        selectedMatch = nil
        articleState = .idle
    }

    func search(text: String, includeHistory: Bool) {
        let generation = searchRequests.advance()
        searchTask?.cancel()
        searchTask = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pendingSearch = nil
            searchHits = []
            searchState = .idle
            return
        }

        let request = PendingSearch(
            text: trimmed,
            includeHistory: includeHistory,
            generation: generation)
        pendingSearch = request
        searchHits = []
        searchState = .searching
        guard state == .ready else { return }
        guard let store else {
            searchState = .failed
            return
        }
        startSearch(request, store: store)
    }

    private func startSearch(_ request: PendingSearch, store: MechanicianHelpStore) {
        searchTask = Task { [weak self] in
            do {
                let hits = try await store.search(MechanicianHelpSearchRequest(
                    text: request.text,
                    mode: .typeahead,
                    includeHistory: request.includeHistory,
                    limit: 16))
                guard !Task.isCancelled,
                      let self,
                      self.searchRequests.accepts(request.generation) else { return }
                self.searchHits = hits
                self.searchState = hits.isEmpty ? .empty : .results
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.searchRequests.accepts(request.generation) else { return }
                self.searchHits = []
                self.searchState = .failed
            }
        }
    }

    nonisolated static func excerpt(_ body: String, matching query: String, limit: Int = 210) -> String {
        let prose = body
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard prose.count > limit else { return prose }
        let terms = query.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let firstMatch = terms.compactMap { term in
            prose.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound
        }.min()
        let center = firstMatch.map { prose.distance(from: prose.startIndex, to: $0) } ?? 0
        let startOffset = max(0, min(center - limit / 3, prose.count - limit))
        let start = prose.index(prose.startIndex, offsetBy: startOffset)
        let end = prose.index(start, offsetBy: min(limit, prose.distance(from: start, to: prose.endIndex)))
        let excerpt = String(prose[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(startOffset > 0 ? "…" : "")\(excerpt)\(end < prose.endIndex ? "…" : "")"
    }

    private func finishOpening(_ opened: MechanicianHelpStore) async throws {
        let catalog = try await opened.listSections()
        let currentGuides = try await opened.guides()
        guard !Task.isCancelled else { return }
        store = opened
        metadata = opened.metadata
        sections = catalog
        guides = currentGuides
        state = .ready
        if let pendingSearch {
            startSearch(pendingSearch, store: opened)
        }
    }

    private func markUnavailable() {
        state = .unavailable
        sections = []
        guides = []
        metadata = nil
        clearArticleSelection()
        searchTask?.cancel()
        searchTask = nil
        searchHits = []
        if pendingSearch != nil {
            searchState = .failed
        } else {
            searchState = .idle
        }
    }
}

/// A cancellation check alone is not enough when an actor operation completes at the same instant
/// its caller starts a replacement. The returned token lets presentation state reject that stale
/// completion deterministically.
struct HelpRequestGeneration: Equatable {
    private(set) var current = 0

    mutating func advance() -> Int {
        current += 1
        return current
    }

    func accepts(_ generation: Int) -> Bool {
        generation == current
    }
}
