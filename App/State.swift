import Foundation
import Observation
import AppKit
import Core

// MARK: - Tab: one directory view with its own selection & cursor

@MainActor
@Observable
final class TabModel: Identifiable {
    let id = UUID()
    private let fs: FileSystemProvider
    private let tags: TagServing

    private(set) var directory: URL
    private(set) var state: ListingState = .idle
    var sortOrder = SortOrder()
    var showHidden = false

    /// Multi-selection + the keyboard cursor (focused row).
    var selection: Set<URL> = []
    var cursor: URL?

    private var task: Task<Void, Never>?

    init(fs: FileSystemProvider, tags: TagServing, directory: URL) {
        self.fs = fs
        self.tags = tags
        self.directory = directory
    }

    var title: String { directory.lastPathComponent.isEmpty ? "/" : directory.lastPathComponent }

    /// Entries after hidden-filter + sort. The single source the table renders.
    var displayed: [FSEntry] {
        let base: [FSEntry]
        switch state {
        case .loading(let p): base = p
        case .loaded(let e): base = e
        default: base = []
        }
        let filtered = showHidden ? base : base.filter { !$0.isHidden }
        return filtered.sorted(by: sortOrder)
    }

    func open(_ url: URL) {
        directory = url
        selection = []
        cursor = nil
        load()
    }

    func goUp() {
        let parent = directory.deletingLastPathComponent()
        if parent != directory { open(parent) }
    }

    func load() {
        task?.cancel()
        state = .loading(partial: [])
        let stream = fs.list(directory)
        task = Task { [weak self] in
            var partial: [FSEntry] = []
            for await event in stream {
                guard let self else { return }
                switch event {
                case .began: break
                case .entries(let batch):
                    partial.append(contentsOf: batch)
                    self.state = .loading(partial: partial)
                case .finished:
                    self.state = .loaded(partial)
                    if self.cursor == nil { self.cursor = self.displayed.first?.url }
                    await self.fillTags(partial, forDirectory: self.directory)
                case .failed(let message):
                    self.state = .failed(message)
                }
            }
        }
    }

    /// Lazily attach tags without blocking the listing. Bails if the user
    /// navigated away mid-fill so stale entries never overwrite the new dir.
    private func fillTags(_ entries: [FSEntry], forDirectory dir: URL) async {
        guard case .loaded(var current) = state, directory == dir else { return }
        for i in current.indices {
            if directory != dir { return }
            current[i].tags = await tags.tags(of: current[i].url)
        }
        guard directory == dir, case .loaded = state else { return }
        state = .loaded(current)
    }

    // MARK: Keyboard cursor movement

    func moveCursor(by delta: Int, extend: Bool) {
        let rows = displayed
        guard !rows.isEmpty else { return }
        let idx = rows.firstIndex { $0.url == cursor } ?? 0
        let next = max(0, min(rows.count - 1, idx + delta))
        let target = rows[next].url
        cursor = target
        if extend { selection.insert(target) } else { selection = [target] }
    }

    func toggleSelectCursor() {
        guard let c = cursor else { return }
        if selection.contains(c) { selection.remove(c) } else { selection.insert(c) }
    }

    /// The entries the user is acting on: explicit selection, else the cursor row.
    var actionable: [FSEntry] {
        let rows = displayed
        if !selection.isEmpty { return rows.filter { selection.contains($0.url) } }
        if let c = cursor { return rows.filter { $0.url == c } }
        return []
    }
}

// MARK: - Pane: a stack of tabs

@MainActor
@Observable
final class PaneModel: Identifiable {
    let id = UUID()
    private let fs: FileSystemProvider
    private let tags: TagServing

    var tabs: [TabModel]
    var activeIndex = 0

    init(fs: FileSystemProvider, tags: TagServing, directory: URL) {
        self.fs = fs
        self.tags = tags
        self.tabs = [TabModel(fs: fs, tags: tags, directory: directory)]
    }

    var active: TabModel { tabs[min(activeIndex, tabs.count - 1)] }

    func newTab(at directory: URL? = nil) {
        let dir = directory ?? active.directory
        tabs.append(TabModel(fs: fs, tags: tags, directory: dir))
        activeIndex = tabs.count - 1
        active.load()
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        activeIndex = min(activeIndex, tabs.count - 1)
    }

    func select(_ id: UUID) {
        if let i = tabs.firstIndex(where: { $0.id == id }) { activeIndex = i }
    }
}

// MARK: - A running operation shown in the queue

@MainActor
@Observable
final class OperationItem: Identifiable {
    let id: UUID
    let task: OperationTask
    var progress: OperationProgress

    init(task: OperationTask) {
        self.id = task.id
        self.task = task
        self.progress = OperationProgress(id: task.id, completedBytes: 0, totalBytes: 0, currentFile: nil, state: .running)
    }

    var isTerminal: Bool {
        switch progress.state {
        case .done, .failed, .cancelled: return true
        case .running: return false
        }
    }
}

// MARK: - App state: two panes + shared services

@MainActor
@Observable
final class AppState {
    let fs: FileSystemProvider = LocalFileSystem()
    let tags: TagServing = TagService()
    let engine = FileEngine()
    let registry = ExtensionRegistry()

    let left: PaneModel
    let right: PaneModel
    var activePaneIsLeft = true

    var operations: [OperationItem] = []
    var bookmarks: [Bookmark]
    var colorCoder = ColorCoder()
    var showPreview = false

    // Bulk-rename + tag sheets driven from the UI.
    var renameSheet: Bool = false

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        left = PaneModel(fs: fs, tags: tags, directory: home)
        right = PaneModel(fs: fs, tags: tags, directory: home)
        bookmarks = AppState.defaultBookmarks()
    }

    var activePane: PaneModel { activePaneIsLeft ? left : right }
    var inactivePane: PaneModel { activePaneIsLeft ? right : left }
    var activeTab: TabModel { activePane.active }

    func switchPane() { activePaneIsLeft.toggle() }

    func start() {
        left.active.load()
        right.active.load()
    }

    // MARK: Command dispatch

    func run(_ commandID: String) {
        switch commandID {
        case CommandID.switchPane: switchPane()
        case CommandID.goUp: activeTab.goUp()
        case CommandID.open: openCursor()
        case CommandID.toggleHidden: activeTab.showHidden.toggle()
        case CommandID.copy: enqueue(.copy, to: inactivePane.active.directory)
        case CommandID.move: enqueue(.move, to: inactivePane.active.directory)
        case CommandID.delete: enqueueDelete()
        case CommandID.rename: renameSheet = true
        case CommandID.newTab: activePane.newTab()
        case CommandID.closeTab: activePane.closeTab(activePane.active.id)
        case CommandID.togglePreview: showPreview.toggle()
        default: break
        }
    }

    func openCursor() {
        guard let entry = activeTab.actionable.first ?? activeTab.displayed.first(where: { $0.url == activeTab.cursor }) else { return }
        if entry.isDirectory { activeTab.open(entry.url) }
        else { openFile(entry.url) }
    }

    // MARK: File operations

    func enqueue(_ kind: FileOperationKind, to destination: URL) {
        let sources = activeTab.actionable.map(\.url)
        guard !sources.isEmpty else { return }
        let task = OperationTask(kind: kind, sources: sources, destination: destination)
        runTask(task) { [weak self] in
            self?.inactivePane.active.load()
            if case .move = kind { self?.activeTab.load() }
        }
    }

    func enqueueDelete() {
        let sources = activeTab.actionable.map(\.url)
        guard !sources.isEmpty else { return }
        let task = OperationTask(kind: .delete, sources: sources)
        runTask(task) { [weak self] in self?.activeTab.load() }
    }

    func rename(to newName: String) {
        guard let entry = activeTab.actionable.first, !newName.isEmpty else { return }
        rename(entry: entry, to: newName)
    }

    func rename(entry: FSEntry, to newName: String) {
        // Must be a plain leaf name — reject path traversal ("../etc/passwd").
        guard !newName.isEmpty, !newName.contains("/"), newName != ".", newName != ".." else { return }
        let task = OperationTask(kind: .rename(to: newName), sources: [entry.url])
        runTask(task) { [weak self] in self?.activeTab.load() }
    }

    /// Open a file in its default app, confirming first for executable/script
    /// types (this app is non-sandboxed with full disk access).
    func openFile(_ url: URL) {
        let risky: Set<String> = ["sh", "command", "zsh", "bash", "scpt", "workflow", "app", "term", "tool"]
        if risky.contains(url.pathExtension.lowercased()) {
            let alert = NSAlert()
            alert.messageText = "Open “\(url.lastPathComponent)”?"
            alert.informativeText = "This may run code on your Mac."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        NSWorkspace.shared.open(url)
    }

    private func runTask(_ task: OperationTask, onFinish: @escaping () -> Void) {
        let item = OperationItem(task: task)
        operations.append(item)
        Task { @MainActor in
            for await p in engine.run(task) {
                item.progress = p
            }
            onFinish()
            // Drop finished rows after a beat so the user sees completion.
            try? await Task.sleep(for: .seconds(2))
            operations.removeAll { $0.id == task.id && $0.isTerminal }
        }
    }

    func cancel(_ id: UUID) {
        Task { await engine.cancel(id) }
    }

    static func defaultBookmarks() -> [Bookmark] {
        let h = FileManager.default.homeDirectoryForCurrentUser
        return [
            Bookmark(name: "Home", path: h.path),
            Bookmark(name: "Documents", path: h.appendingPathComponent("Documents").path),
            Bookmark(name: "Downloads", path: h.appendingPathComponent("Downloads").path),
            Bookmark(name: "Desktop", path: h.appendingPathComponent("Desktop").path),
        ]
    }
}
