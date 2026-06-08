import Foundation
import Core

// MARK: - Search domain extracted from AppState (A-3)

@MainActor
@Observable
final class SearchCoordinator {
    private let searchService: SearchService
    private let fs: FileSystemProvider
    private let tags: TagServing

    // AppState wires this after its own init.
    var activeTabGetter: (() -> TabModel)?

    // MARK: Observed state

    var searchActive = false
    var searchQuery = ""
    var searchMode: SearchMode = .name
    var searchRunning = false
    var searchHitCount = 0

    private var searchTask: Task<Void, Never>?

    init(searchService: SearchService, fs: FileSystemProvider, tags: TagServing) {
        self.searchService = searchService
        self.fs = fs
        self.tags = tags
    }

    // MARK: Search

    func runSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let tab = activeTabGetter?() else { return }
        let dir = tab.directory
        let mode = searchMode
        searchTask?.cancel()
        searchRunning = true
        searchHitCount = 0
        let label = mode == .content ? "Contents: \(q)" : "Search: \(q)"
        tab.beginVirtual(title: label, origin: dir)
        searchTask = Task { [weak self] in
            guard let self else { return }
            var entries: [FSEntry] = []
            for await url in self.searchService.searchStream(q, in: dir, mode: mode) {
                if Task.isCancelled { self.searchRunning = false; return }
                guard var e = try? await self.fs.metadata(of: url) else { continue }
                e.tags = await self.tags.tags(of: url)
                entries.append(e)
                self.searchHitCount = entries.count
                if entries.count % 32 == 0 { tab.appendVirtual(entries) }
            }
            if Task.isCancelled { self.searchRunning = false; return }
            tab.appendVirtual(entries)
            self.searchRunning = false
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchRunning = false
        searchActive = false
    }
}
