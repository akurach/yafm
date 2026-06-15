import Foundation
import Observation
import AppKit
import Core

// MARK: - Tab: one directory view with its own selection & cursor

enum PaneViewMode: String { case list, icons }

@MainActor
@Observable
final class TabModel: Identifiable {
    let id = UUID()
    var viewMode: PaneViewMode = .list
    private let fs: FileSystemProvider
    private let tags: TagServing
    private let git: GitStatusService?

    private(set) var directory: URL
    private(set) var state: ListingState = .idle { didSet { recomputeDisplayed() } }
    var sortOrder = SortOrder() { didSet { recomputeDisplayed() } }
    var showHidden = false { didSet { recomputeDisplayed() } }

    /// Type-to-filter: a live name substring the user typed into the pane. Empty
    /// = inactive. `filterActive` tracks the typing session so Esc/Backspace
    /// behave even after the text is emptied. Changing it re-derives `displayed`.
    private(set) var filter = "" { didSet { recomputeDisplayed() } }
    private(set) var filterActive = false

    func appendFilter(_ s: String) { filterActive = true; filter += s }
    func backspaceFilter() {
        guard filterActive else { return }
        if filter.isEmpty { filterActive = false } else { filter.removeLast() }
    }
    func clearFilter() { filterActive = false; filter = "" }

    /// Non-nil when the tab shows a virtual listing (e.g. "everything tagged X")
    /// instead of a real directory. Cleared the moment the user navigates.
    private(set) var virtualName: String?
    /// The directory a virtual (search) listing was launched from, so the
    /// results pane can show "results in <origin>" and offer a way back.
    private(set) var virtualOrigin: URL?

    /// Multi-selection + the keyboard cursor (focused row).
    var selection: Set<URL> = []
    var cursor: URL?

    /// VCS markers for the entries in this listing, keyed by entry URL. Filled
    /// asynchronously after a directory finishes loading; empty outside a repo.
    private(set) var gitStatus: [URL: String] = [:]

    /// Called whenever the tab navigates to a new real directory (not virtual/refresh).
    var onNavigate: ((URL) -> Void)?

    private var task: Task<Void, Never>?
    private var gitTask: Task<Void, Never>?

    init(fs: FileSystemProvider, tags: TagServing, directory: URL, showHidden: Bool = false,
         git: GitStatusService? = nil) {
        self.fs = fs
        self.tags = tags
        self.git = git
        self.directory = directory
        self.showHidden = showHidden
    }

    var title: String {
        if let v = virtualName { return v }
        return directory.lastPathComponent.isEmpty ? "/" : directory.lastPathComponent
    }

    /// True while a directory is still streaming in. The table suppresses row
    /// animations during this window so partial-batch inserts don't tear (v0.5
    /// scoped-animation: selection/nav still glides once loaded).
    var isStreaming: Bool { if case .loading = state { true } else { false } }

    /// Entries after hidden-filter + sort. The single source the table renders.
    /// Cached: recomputed only when `state`/`sortOrder`/`showHidden` change, not
    /// on every access (the table read + re-sorted it per render before).
    private(set) var displayed: [FSEntry] = []

    private func recomputeDisplayed() {
        let base: [FSEntry]
        let streaming: Bool
        switch state {
        case .loading(let p): base = p; streaming = true
        case .loaded(let e): base = e; streaming = false
        default: base = []; streaming = false
        }
        var filtered = showHidden ? base : base.filter { !$0.isHidden }
        if filterActive, !filter.isEmpty {
            filtered = filtered.filter { $0.name.range(of: filter, options: .caseInsensitive) != nil }
        }
        // PERF: sorting the whole *growing* partial on every stream batch was
        // O(n²) `localizedStandard` work on the main actor — it froze big folders
        // (Downloads). While streaming, show arrival order (row animation is
        // suppressed anyway); sort once when the listing is complete.
        displayed = streaming ? filtered : filtered.sorted(by: sortOrder)
        // PERF: index by URL once so cursor moves / `actionable` are O(1) instead
        // of an O(n) linear scan per keystroke (perf P2-F/P2-G).
        var idx: [URL: Int] = [:]
        idx.reserveCapacity(displayed.count)
        for (i, e) in displayed.enumerated() { idx[e.url] = i }
        displayedIndex = idx
        // Keep the cursor on a visible row as the filter narrows the list. Only
        // needed while filtering — the O(n) scan was wasted on every batch.
        if filterActive, let c = cursor, displayedIndex[c] == nil {
            cursor = displayed.first?.url
        }
    }

    /// URL → row index in `displayed`, rebuilt with it (perf).
    private(set) var displayedIndex: [URL: Int] = [:]

    func open(_ url: URL) {
        virtualName = nil
        directory = url
        selection = []
        cursor = nil
        gitStatus = [:]
        clearFilter()
        onNavigate?(url)
        load()
    }

    /// Begin a virtual listing (tag cloud, search results) — not tied to
    /// `directory`; Refresh/navigation leaves it. Entries stream in via
    /// `appendVirtual` so a large set fills progressively.
    func beginVirtual(title: String, origin: URL? = nil) {
        task?.cancel()
        virtualName = title
        virtualOrigin = origin
        selection = []
        cursor = nil
        state = .loaded([])
    }

    /// Replace the virtual listing's entries with the latest accumulated set.
    /// No-op once the user has navigated away (virtualName cleared).
    func appendVirtual(_ entries: [FSEntry]) {
        guard virtualName != nil else { return }
        state = .loaded(entries)
        if cursor == nil { cursor = displayed.first?.url }
    }

    func goUp() {
        let parent = directory.deletingLastPathComponent()
        if parent != directory { open(parent) }
    }

    func load() {
        task?.cancel()
        virtualName = nil   // a real directory listing exits virtual (tag) mode
        state = .loading(partial: [])
        let stream = fs.list(directory)
        task = Task { [weak self] in
            var partial: [FSEntry] = []
            var lastShown = 0
            for await event in stream {
                guard let self else { return }
                switch event {
                case .began: break
                case .entries(let batch):
                    partial.append(contentsOf: batch)
                    // PERF: coalesce stream updates so the table re-renders a
                    // handful of times for a 10k folder, not once per 128-file
                    // batch. Flush the first batch immediately (instant feedback,
                    // incl. slow SMB dirs), then every 500; `.finished` flushes
                    // the full set.
                    if lastShown == 0 || partial.count - lastShown >= 500 {
                        lastShown = partial.count
                        self.state = .loading(partial: partial)
                    }
                case .finished:
                    self.state = .loaded(partial)
                    if self.cursor == nil { self.cursor = self.displayed.first?.url }
                    self.refreshGitStatus(for: self.directory)
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
        guard case .loaded = state, directory == dir else { return }
        // PERF: one in-memory batch lookup, NOT a live xattr read per file. The
        // old loop did `getxattr` for all ~N files on every folder open (seconds
        // on Downloads) and then re-sorted N even when nothing was tagged. Now we
        // only touch the UI when some file actually carries a tag.
        let byURL = await tags.cachedTags(for: entries.map(\.url))
        guard !byURL.isEmpty, directory == dir, case .loaded(var current) = state else { return }
        for i in current.indices {
            if let t = byURL[current[i].url] { current[i].tags = t }
        }
        state = .loaded(current)
    }

    /// Ask the git service for child statuses and key them by entry URL. A new
    /// listing supersedes any in-flight compute; a navigated-away result is dropped.
    private func refreshGitStatus(for dir: URL) {
        guard let git else { return }
        gitTask?.cancel()
        gitTask = Task { [weak self] in
            let map = await git.status(forDirectory: dir)
            guard let self, self.directory == dir, self.virtualName == nil else { return }
            var keyed: [URL: String] = [:]
            for (name, marker) in map {
                keyed[dir.appendingPathComponent(name)] = marker
            }
            self.gitStatus = keyed
        }
    }

    // MARK: Keyboard cursor movement

    func moveCursor(by delta: Int, extend: Bool) {
        let rows = displayed
        guard !rows.isEmpty else { return }
        let idx = cursor.flatMap { displayedIndex[$0] } ?? 0   // O(1) (perf P2-F)
        let next = max(0, min(rows.count - 1, idx + delta))
        let target = rows[next].url
        cursor = target
        if extend { selection.insert(target) } else { selection = [target] }
    }

    /// Move the cursor to an absolute row (Home/End/PageUp/PageDown).
    func moveCursor(to index: Int, extend: Bool) {
        let rows = displayed
        guard !rows.isEmpty else { return }
        let target = rows[max(0, min(rows.count - 1, index))].url
        cursor = target
        if extend { selection.insert(target) } else { selection = [target] }
    }

    func toggleSelectCursor() {
        guard let c = cursor else { return }
        if selection.contains(c) { selection.remove(c) } else { selection.insert(c) }
    }

    /// Insert-style: toggle the cursor row's membership, then advance the cursor
    /// WITHOUT clearing the selection (the Total Commander multi-pick gesture).
    func toggleSelectAndAdvance() {
        toggleSelectCursor()
        let rows = displayed
        guard !rows.isEmpty, let i = cursor.flatMap({ displayedIndex[$0] }) else { return }
        cursor = rows[min(rows.count - 1, i + 1)].url
    }

    func selectAll() { selection = Set(displayed.map(\.url)) }

    /// Select the contiguous range between two rows (⇧-click).
    func selectRange(from anchor: URL, to target: URL) {
        guard let a = displayedIndex[anchor], let b = displayedIndex[target] else { return }
        let lo = min(a, b), hi = max(a, b)
        selection = Set(displayed[lo...hi].map(\.url))
    }

    func invertSelection() {
        let all = Set(displayed.map(\.url))
        selection = all.subtracting(selection)
    }

    /// The entries the user is acting on: explicit selection, else the cursor row.
    var actionable: [FSEntry] {
        let rows = displayed
        if !selection.isEmpty { return rows.filter { selection.contains($0.url) } }
        if let c = cursor, let i = displayedIndex[c] { return [rows[i]] }   // O(1) (perf P2-G)
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
    private let git: GitStatusService?

    var tabs: [TabModel]
    var activeIndex = 0
    /// Called when any tab in this pane navigates to a new directory.
    var onTabNavigate: ((URL) -> Void)?
    /// New tabs inherit this (from `AppSettings.showHiddenByDefault`).
    private let defaultShowHidden: Bool

    init(fs: FileSystemProvider, tags: TagServing, directory: URL, showHidden: Bool = false,
         git: GitStatusService? = nil) {
        self.fs = fs
        self.tags = tags
        self.git = git
        self.defaultShowHidden = showHidden
        let initial = TabModel(fs: fs, tags: tags, directory: directory, showHidden: showHidden, git: git)
        self.tabs = [initial]
        initial.onNavigate = { [weak self] url in self?.onTabNavigate?(url) }
    }

    // Invariant: `tabs` is never empty — seeded with one in init, and closeTab
    // refuses to remove the last. `active` relies on it; assert so a future edit
    // that breaks the invariant fails loudly in debug instead of crashing on index.
    var active: TabModel {
        assert(!tabs.isEmpty, "PaneModel.tabs must never be empty")
        return tabs[min(activeIndex, tabs.count - 1)]
    }

    func newTab(at directory: URL? = nil) {
        let dir = directory ?? active.directory
        let tab = TabModel(fs: fs, tags: tags, directory: dir, showHidden: defaultShowHidden, git: git)
        tab.onNavigate = { [weak self] url in self?.onTabNavigate?(url) }
        tabs.append(tab)
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

    /// Cycle tabs (⌃Tab / ⌃⇧Tab), wrapping around.
    func cycleTab(by delta: Int) {
        guard tabs.count > 1 else { return }
        activeIndex = (activeIndex + delta + tabs.count) % tabs.count
    }

    /// Jump to tab N (⌘1–⌘9); 1-based, out-of-range is ignored.
    func selectIndex(_ n: Int) {
        guard n >= 1, n <= tabs.count else { return }
        activeIndex = n - 1
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
    // Routed through FileSystemRouter so virtual filesystems (SMB/FTP in v0.7,
    // archives in v0.8) register by scheme without touching any call site.
    let fs: FileSystemProvider = FileSystemRouter()
        .registering(SMBFileSystem(), for: "smb")
        .registering(ArchiveFileSystem(), for: "archive")   // read-only .zip browse (v0.8)
    let tags: TagServing = TagService()
    let engine = FileEngine()
    let settings = AppSettings()
    let gitService = GitStatusService()
    let volumeService = VolumeService()

    // MARK: Domain coordinators (A-3: God Object split)

    let plugins: PluginCoordinator
    let tagCloud: TagCoordinator
    let search: SearchCoordinator

    // MARK: Forwarding accessors — views use app.xxx without knowing the coordinator

    var registry: ExtensionRegistry { plugins.registry }
    var pluginHost: JSPluginHost { plugins.pluginHost }
    var pluginValueCache: PluginValueCache { plugins.pluginValueCache }
    var pluginValuesVersion: Int {
        get { plugins.pluginValuesVersion }
        set { plugins.pluginValuesVersion = newValue }
    }
    var disabledPluginIDs: Set<String> {
        get { plugins.disabledPluginIDs }
        set { plugins.disabledPluginIDs = newValue }
    }

    var knownTags: [Tag] { tagCloud.knownTags }
    var tagCounts: [String: Int] { tagCloud.tagCounts }

    var searchActive: Bool {
        get { search.searchActive }
        set { search.searchActive = newValue }
    }
    var searchQuery: String {
        get { search.searchQuery }
        set { search.searchQuery = newValue }
    }
    var searchMode: SearchMode {
        get { search.searchMode }
        set { search.searchMode = newValue }
    }
    var searchRunning: Bool {
        get { search.searchRunning }
        set { search.searchRunning = newValue }
    }
    var searchHitCount: Int {
        get { search.searchHitCount }
        set { search.searchHitCount = newValue }
    }

    // MARK: Panes

    let left: PaneModel
    let right: PaneModel
    var activePaneIsLeft = true

    var operations: [OperationItem] = []
    var bookmarks: [Bookmark]
    var colorCoder = ColorCoder()
    var showPreview = false

    /// The right inspector has two modes (§4): metadata vs large QuickLook.
    enum InspectorMode { case info, preview }
    var inspectorMode: InspectorMode = .info

    /// Mounted volumes for the sidebar, kept live via mount/unmount notifications.
    var volumes: [Volume] = []
    /// Async-enriched classification for each mounted volume (keyed by mount URL).
    var volumeClassifications: [URL: VolumeClassification] = [:]
    @ObservationIgnored private var classificationTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private let volumeCollector = VolumeInfoCollector()

    // Not observed by the UI; `nonisolated(unsafe)` lets the nonisolated deinit
    // remove the tokens. They're only mutated on the main actor during setup and
    // read in deinit when no other reference survives (H-1).
    @ObservationIgnored nonisolated(unsafe) private var volumeObservers: [NSObjectProtocol] = []

    /// Access onboarding (§6).
    var hasFullDiskAccess = true
    var showOnboarding = false
    var bannerDismissed = false
    private static let didOnboardKey = "didOnboard"

    var renameSheet: Bool = false

    struct TagSheetItem: Identifiable { let url: URL; var id: URL { url } }
    var tagSheet: TagSheetItem?

    /// Internal copy/cut buffer. Paste enqueues a copy or move.
    var clipboard: (urls: [URL], cut: Bool)?

    // MARK: Command palette / cheat sheet overlay

    var commandPalette = false
    var cheatSheet = false

    /// Connect-to-Server (⌘⇧K): the smb:// address sheet (v0.7).
    var connectSheet = false
    var connectAddress = "smb://"

    private static let bookmarksKey = "yafm.customBookmarks"

    init() {
        // Coordinators first — they only need the shared services as init params
        // and those are set via their inline default initializers before this body runs.
        let tagsService = tags as TagServing   // capture typed ref before self is available
        let fsService   = fs  as FileSystemProvider
        plugins  = PluginCoordinator()
        tagCloud = TagCoordinator(tags: tagsService, fs: fsService)
        search   = SearchCoordinator(
            searchService: SearchService(),
            fs: fsService,
            tags: tagsService
        )

        let start = settings.startDirectory()
        let hidden = settings.showHiddenByDefault
        left  = PaneModel(fs: fsService, tags: tagsService, directory: start, showHidden: hidden, git: gitService)
        right = PaneModel(fs: fsService, tags: tagsService, directory: start, showHidden: hidden, git: gitService)

        if let data = UserDefaults.standard.data(forKey: Self.bookmarksKey),
           let saved = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = saved
        } else {
            bookmarks = []
        }

        // Post-init: wire closures that need a fully initialised self (Phase 2).
        left.onTabNavigate  = { [weak self] url in self?.onAnyTabNavigate(url) }
        right.onTabNavigate = { [weak self] url in self?.onAnyTabNavigate(url) }

        tagCloud.onReloadActiveTab = { [weak self] in self?.activeTab.load() }
        tagCloud.activeTabGetter   = { [weak self] in self!.activeTab }
        search.activeTabGetter     = { [weak self] in self!.activeTab }
    }

    var activePane: PaneModel { activePaneIsLeft ? left : right }
    var inactivePane: PaneModel { activePaneIsLeft ? right : left }
    var activeTab: TabModel { activePane.active }

    func switchPane() { activePaneIsLeft.toggle() }

    /// Open a URL in a fresh tab of the active pane (sidebar "Open in New Tab").
    func openInNewTab(_ url: URL) { activePane.newTab(at: url) }

    /// Called by either pane on any directory navigation.
    /// Clears the readText call budget (S-H3) and saves lastFolder for crash recovery (A-10).
    private func onAnyTabNavigate(_ url: URL) {
        plugins.pluginHost.clearHandles()
        settings.rememberLastFolder(url)
    }

    // MARK: Start

    func start() {
        settings.applyTheme()
        left.active.load()
        right.active.load()
        refreshVolumes()
        observeVolumes()
        tagCloud.indexTagsInBackground()
        checkAccess()
        plugins.loadPlugins()
    }

    // MARK: Favorites (sidebar)

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: Self.bookmarksKey)
        }
    }

    func addBookmark(_ url: URL) {
        guard !bookmarks.contains(where: { $0.path == url.path }) else { return }
        let name = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
        bookmarks.append(Bookmark(name: name, path: url.path))
        saveBookmarks()
    }

    func removeBookmark(_ bm: Bookmark) {
        bookmarks.removeAll { $0.id == bm.id }
        saveBookmarks()
    }

    // MARK: Plugin forwarding

    func loadPlugins()    { plugins.loadPlugins() }
    func revealPluginsFolder() { plugins.revealPluginsFolder() }
    func availablePlugins() -> [(id: String, name: String, manifest: PluginManifest?, enabled: Bool)] {
        plugins.availablePlugins()
    }
    func setPlugin(_ id: String, enabled: Bool) { plugins.setPlugin(id, enabled: enabled) }
    func pluginCommands()  -> [(id: String, title: String)] { plugins.pluginCommands() }
    func pluginMenuItems() -> [(id: String, title: String)] { plugins.pluginMenuItems() }
    func runPluginMenuItem(_ id: String, on entry: FSEntry) { plugins.runPluginMenuItem(id, on: entry) }

    // MARK: Tag forwarding

    func refreshTags()              { tagCloud.refreshTags() }
    func rescanTags()               { tagCloud.rescanTags() }
    func clearTags()                { tagCloud.clearTags() }
    func renameTag(_ old: String, to new: String) { tagCloud.renameTag(old, to: new) }
    func deleteTag(_ name: String)  { tagCloud.deleteTag(name) }
    func recolorTag(_ name: String, colorIndex: Int?) { tagCloud.recolorTag(name, colorIndex: colorIndex) }
    func promptRenameTag(_ tag: Tag) { tagCloud.promptRenameTag(tag) }
    func promptDeleteTag(_ tag: Tag) { tagCloud.promptDeleteTag(tag) }
    func openTag(_ tag: Tag)        { tagCloud.openTag(tag) }
    func toggleColorTag(name: String, colorIndex: Int, on entry: FSEntry) {
        tagCloud.toggleColorTag(name: name, colorIndex: colorIndex, on: entry)
    }
    func addTag(_ name: String, on entry: FSEntry) { tagCloud.addTag(name, on: entry) }
    func writeTags(_ newTags: [Tag], on url: URL)  { tagCloud.writeTags(newTags, on: url) }
    func currentTags(of url: URL) async -> [Tag]   { await tagCloud.currentTags(of: url) }
    func promptNewTag(on entry: FSEntry)            { tagCloud.promptNewTag(on: entry) }

    // MARK: Search forwarding

    func runSearch(_ query: String) { search.runSearch(query) }
    func cancelSearch()             { search.cancelSearch() }

    /// Open an `smb://` (or any) network address in the active pane.
    func connectToServer(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed: Set<String> = ["smb", "ftp", "sftp", "nfs", "afp", "dav", "davs"]
        guard let url = URL(string: trimmed),
              allowed.contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return }
        connectSheet = false
        var recent = settings.recentServers.filter { $0 != trimmed }
        recent.insert(trimmed, at: 0)
        settings.recentServers = Array(recent.prefix(5))
        activeTab.open(url)
    }

    // MARK: Share / AirDrop

    func sharingServices(for urls: [URL]) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: urls)
    }

    func share(_ urls: [URL], with service: NSSharingService) {
        guard !urls.isEmpty else { return }
        service.perform(withItems: urls)
    }

    func sharePicker(for urls: [URL]) {
        guard !urls.isEmpty, let window = NSApp.keyWindow, let content = window.contentView else { return }
        let picker = NSSharingServicePicker(items: urls)
        let pt = window.mouseLocationOutsideOfEventStream
        let rect = NSRect(x: pt.x, y: pt.y, width: 1, height: 1)
        picker.show(relativeTo: rect, of: content, preferredEdge: .minY)
    }

    // MARK: Volumes (§2)

    func refreshVolumes() {
        let prev = Set(volumes.map(\.url))
        volumes = volumeService.mountedVolumes()
        let curr = Set(volumes.map(\.url))

        for url in prev.subtracting(curr) {
            classificationTasks[url]?.cancel()
            classificationTasks.removeValue(forKey: url)
            volumeClassifications.removeValue(forKey: url)
        }

        for vol in volumes where volumeClassifications[vol.url] == nil
                              && classificationTasks[vol.url] == nil {
            let collector = volumeCollector
            let v = vol
            classificationTasks[vol.url] = Task.detached { [weak self] in
                let c = collector.collect(volume: v)
                guard !Task.isCancelled, let self else { return }
                await MainActor.run { self.volumeClassifications[v.url] = c }
            }
        }
    }

    private func observeVolumes() {
        guard volumeObservers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        for name in names {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshVolumes() }
            }
            volumeObservers.append(token)
        }
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        for token in volumeObservers { nc.removeObserver(token) }
        for task in classificationTasks.values { task.cancel() }
    }

    func eject(_ volume: Volume) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let volPath = volume.url.standardizedFileURL.path
        for pane in [left, right] {
            for tab in pane.tabs where tab.directory.standardizedFileURL.path.hasPrefix(volPath) {
                tab.open(home)
            }
        }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
        } catch {
            let volName = volume.name
            let volURL  = volume.url
            Task { @MainActor in
                let procs = await Self.busyProcesses(on: volURL, timeout: 3)
                let alert = NSAlert()
                alert.messageText = "Could not eject \"\(volName)\""
                if procs.isEmpty {
                    alert.informativeText = "Another app may still have a file on this disk open. Close it and try again."
                } else {
                    let list = procs.map { "  • \($0)" }.joined(separator: "\n")
                    alert.informativeText = "The following apps are using files on this disk:\n\n\(list)\n\nQuit them or close their files, then try again."
                }
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
        refreshVolumes()
    }

    private static func busyProcesses(on url: URL, timeout: Double) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                proc.arguments = ["+D", url.path]
                let out = Pipe()
                proc.standardOutput = out
                proc.standardError  = Pipe()
                guard (try? proc.run()) != nil else { cont.resume(returning: []); return }

                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.global().async { proc.waitUntilExit(); sem.signal() }
                guard sem.wait(timeout: .now() + timeout) != .timedOut else {
                    proc.terminate()
                    cont.resume(returning: [])
                    return
                }

                let raw = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                let friendly: [String: String] = [
                    "mds": "Spotlight (mds)",
                    "mds_stores": "Spotlight indexer",
                    "fseventsd": "File Events daemon",
                    "diskarbitrationd": "Disk Arbitration",
                ]
                var seenPIDs = Set<String>()
                var result: [String] = []
                for line in raw.split(separator: "\n").dropFirst() {
                    let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                    guard cols.count >= 2 else { continue }
                    let cmd = String(cols[0])
                    let pid = String(cols[1])
                    guard seenPIDs.insert(pid).inserted else { continue }
                    let name = friendly[cmd] ?? cmd
                    result.append("\(name) (PID \(pid))")
                }
                cont.resume(returning: result)
            }
        }
    }

    // MARK: Access onboarding (§6)

    func checkAccess() {
        if !UserDefaults.standard.bool(forKey: Self.didOnboardKey) {
            showOnboarding = true
        }
        // PERF: the TCC probe does a synchronous open() — run off main actor (P2-10).
        Task { [weak self] in
            let granted = await Task.detached(priority: .userInitiated) { AppState.hasFullDiskAccess() }.value
            self?.hasFullDiskAccess = granted
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.didOnboardKey)
        showOnboarding = false
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probe = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        let fd = open(probe.path, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
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
        case CommandID.delete, CommandID.deletePermanent: enqueueDelete()
        case CommandID.trash: enqueueTrash()
        case CommandID.selectAll: activeTab.selectAll()
        case CommandID.invertSelection: activeTab.invertSelection()
        case CommandID.toggleSelect: activeTab.toggleSelectAndAdvance()
        case CommandID.rename: renameSheet = true
        case CommandID.newTab: activePane.newTab()
        case CommandID.closeTab: activePane.closeTab(activePane.active.id)
        case CommandID.togglePreview: showPreview.toggle()
        case CommandID.clipCopy: clipboardCopy(cut: false)
        case CommandID.clipCut: clipboardCopy(cut: true)
        case CommandID.paste: paste()
        case CommandID.newFolder: newFolder()
        case CommandID.reveal: revealInFinder()
        case CommandID.copyPath: copyPath()
        case CommandID.getInfo: showPreview = true; inspectorMode = .info
        case CommandID.refresh: plugins.pluginValueCache.invalidate(); activeTab.load()
        case CommandID.quickLook, CommandID.view: QuickLook.toggle(urls: activeTab.actionable.map(\.url))
        case CommandID.edit: editCursor()
        case CommandID.search:
            if search.searchActive { search.cancelSearch() } else { search.searchActive = true }
        case CommandID.commandPalette: commandPalette = true
        case CommandID.cheatSheet: cheatSheet = true
        case CommandID.connectServer: connectAddress = "smb://"; connectSheet = true
        case CommandID.nextTab: activePane.cycleTab(by: 1)
        case CommandID.prevTab: activePane.cycleTab(by: -1)
        case let cmd where cmd.hasPrefix(JSPluginHost.commandIDPrefix):
            plugins.pluginHost.runCommand(cmd)
        default: break
        }
    }

    func openCursor(allowFileOpen: Bool = true) {
        guard let entry = activeTab.actionable.first ?? activeTab.displayed.first(where: { $0.url == activeTab.cursor }) else { return }
        if entry.isDirectory { activeTab.open(entry.url) }
        else if entry.url.isFileURL, entry.url.pathExtension.lowercased() == "zip" { browseArchive(entry.url) }
        else if allowFileOpen { openFile(entry.url) }
    }

    func browseArchive(_ zip: URL) {
        guard let url = ArchiveLocation.url(zip: zip, inner: "") else { return }
        activeTab.open(url)
    }

    func enterCursor() { openCursor(allowFileOpen: settings.rightArrowOpensFiles) }

    // MARK: File operations

    func enqueue(_ kind: FileOperationKind, to destination: URL) {
        let sources = activeTab.actionable.map(\.url)
        guard !sources.isEmpty else { return }
        let task = OperationTask(kind: kind, sources: sources, destination: destination,
                                 collision: settings.collisionDefault)
        runTask(task) { [weak self] in
            self?.inactivePane.active.load()
            if case .move = kind {
                self?.tagCloud.forgetTagged(sources)
                self?.activeTab.load()
            }
        }
    }

    func dropEntries(_ sources: [URL], onto destination: URL, move: Bool) {
        let dest = destination.standardizedFileURL
        let filtered = sources.map { $0.standardizedFileURL }.filter { src in
            src != dest
            && src.deletingLastPathComponent().standardizedFileURL != dest
        }
        guard !filtered.isEmpty else { return }
        let task = OperationTask(kind: move ? .move : .copy, sources: filtered,
                                 destination: dest, collision: settings.collisionDefault)
        runTask(task) { [weak self] in
            guard let self else { return }
            let touched = Set([dest] + (move ? filtered.map { $0.deletingLastPathComponent().standardizedFileURL } : []))
            for pane in [self.left, self.right] {
                if touched.contains(pane.active.directory.standardizedFileURL) { pane.active.load() }
            }
            if move { self.tagCloud.forgetTagged(filtered) }
        }
    }

    func enqueueTrash() {
        let sources = activeTab.actionable.map(\.url)
        guard !sources.isEmpty else { return }
        var trashed: [URL] = []
        for url in sources {
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
                trashed.append(url)
            }
        }
        if !trashed.isEmpty {
            tagCloud.forgetTagged(trashed)
            activeTab.load()
        }
    }

    func enqueueDelete() {
        let sources = activeTab.actionable.map(\.url)
        guard !sources.isEmpty else { return }
        if settings.confirmBeforeDelete {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = sources.count == 1
                ? "Delete \"\(sources[0].lastPathComponent)\"?"
                : "Delete \(sources.count) items?"
            alert.informativeText = "This is permanent and can't be undone."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let task = OperationTask(kind: .delete, sources: sources)
        runTask(task) { [weak self] in
            self?.tagCloud.forgetTagged(sources)
            self?.activeTab.load()
        }
    }

    func rename(to newName: String) {
        guard let entry = activeTab.actionable.first, !newName.isEmpty else { return }
        rename(entry: entry, to: newName)
    }

    func rename(entry: FSEntry, to newName: String) {
        guard !newName.isEmpty, !newName.contains("/"), !newName.contains("\0"),
              newName != ".", newName != ".." else { return }
        let task = OperationTask(kind: .rename(to: newName), sources: [entry.url])
        runTask(task) { [weak self] in
            self?.tagCloud.forgetTagged([entry.url])
            self?.activeTab.load()
        }
    }

    func openFile(_ url: URL) {
        if PluginCoordinator.riskyExtensions.contains(url.pathExtension.lowercased()) {
            let alert = NSAlert()
            alert.messageText = "Open \"\(url.lastPathComponent)\"?"
            alert.informativeText = "This may run code on your Mac."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        NSWorkspace.shared.open(url)
    }

    func editCursor() {
        guard let entry = activeTab.actionable.first, !entry.isDirectory else { return }
        openFile(entry.url)
    }

    // MARK: Context-menu commands (v0.2.1)

    func focusContextTarget(_ entry: FSEntry, in tab: TabModel) {
        if !tab.selection.contains(entry.url) {
            tab.selection = [entry.url]
            tab.cursor = entry.url
        }
        activePaneIsLeft = left.tabs.contains { $0.id == tab.id }
    }

    func clipboardCopy(cut: Bool) {
        let urls = activeTab.actionable.map(\.url)
        guard !urls.isEmpty else { return }
        clipboard = (urls, cut)
    }

    func paste() {
        guard let clip = clipboard, !clip.urls.isEmpty else { return }
        let dest = activeTab.directory
        if clip.cut { clipboard = nil }
        let task = OperationTask(kind: clip.cut ? .move : .copy, sources: clip.urls, destination: dest,
                                 collision: settings.collisionDefault)
        runTask(task) { [weak self] in
            if clip.cut { self?.tagCloud.forgetTagged(clip.urls) }
            self?.activeTab.load()
        }
    }

    func newFolder() {
        let parent = activeTab.directory
        let alert = NSAlert()
        alert.messageText = "New Folder"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = "untitled folder"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"),
              name != ".", name != ".." else { return }
        let url = parent.appendingPathComponent(name, isDirectory: true)
        do {
            try engine.makeDirectory(at: url)
            activeTab.load()
            activeTab.cursor = url
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func revealInFinder() {
        let urls = activeTab.actionable.map(\.url)
        guard !urls.isEmpty else {
            NSWorkspace.shared.activateFileViewerSelecting([activeTab.directory]); return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copyPath() {
        let paths = activeTab.actionable.map(\.url.path)
        guard !paths.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    // MARK: Open With

    func applications(for url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    func openFile(_ url: URL, withApplication appURL: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Task { @MainActor in NSAlert(error: error).runModal() }
        }
    }

    func openWithOther(_ url: URL) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let app = panel.url else { return }
        openFile(url, withApplication: app)
    }

    // MARK: Sort

    func sortBy(_ key: SortKey) {
        var order = activeTab.sortOrder
        if order.key == key { order.ascending.toggle() }
        else { order = SortOrder(key: key, ascending: true) }
        activeTab.sortOrder = order
    }

    // MARK: Private helpers

    private func runTask(_ task: OperationTask, onFinish: @escaping () -> Void) {
        let item = OperationItem(task: task)
        operations.append(item)
        Task { @MainActor in
            for await p in engine.run(task) {
                item.progress = p
            }
            onFinish()
            try? await Task.sleep(for: .seconds(2))
            operations.removeAll { $0.id == task.id && $0.isTerminal }
        }
    }

    func cancel(_ id: UUID) {
        engine.cancel(id)
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
