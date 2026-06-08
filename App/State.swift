import Foundation
import Observation
import AppKit
import ImageIO
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
    /// New tabs inherit this (from `AppSettings.showHiddenByDefault`).
    private let defaultShowHidden: Bool

    init(fs: FileSystemProvider, tags: TagServing, directory: URL, showHidden: Bool = false,
         git: GitStatusService? = nil) {
        self.fs = fs
        self.tags = tags
        self.git = git
        self.defaultShowHidden = showHidden
        self.tabs = [TabModel(fs: fs, tags: tags, directory: directory, showHidden: showHidden, git: git)]
    }

    var active: TabModel { tabs[min(activeIndex, tabs.count - 1)] }

    func newTab(at directory: URL? = nil) {
        let dir = directory ?? active.directory
        tabs.append(TabModel(fs: fs, tags: tags, directory: dir, showHidden: defaultShowHidden, git: git))
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
    // archives in v0.8) register by scheme without touching any call site. Today
    // every URL is local and falls through to LocalFileSystem unchanged.
    // SMB registered behind the router (v0.7): `smb://` URLs mount natively and
    // stream like any folder; every other URL still falls through to local.
    let fs: FileSystemProvider = FileSystemRouter()
        .registering(SMBFileSystem(), for: "smb")
        .registering(ArchiveFileSystem(), for: "archive")   // read-only .zip browse (v0.8)
    let tags: TagServing = TagService()
    let engine = FileEngine()
    let registry = ExtensionRegistry()
    let volumeService = VolumeService()
    let settings = AppSettings()
    let gitService = GitStatusService()
    let pluginHost = JSPluginHost()
    let searchService = SearchService()

    /// Memo for async plugin column values (v0.5 seam). `pluginValuesVersion` is
    /// observed by the file table and bumped whenever an async value resolves, so
    /// the affected rows re-render without polling.
    let pluginValueCache = PluginValueCache()
    var pluginValuesVersion = 0

    /// Plugin ids the user disabled in Settings ▸ Plugins (v0.8). Persisted.
    var disabledPluginIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "disabledPlugins") ?? [])

    /// Command palette (⌘K) + shortcut cheat sheet (⌘/) overlay state.
    var commandPalette = false
    var cheatSheet = false

    /// Connect-to-Server (⌘⇧K): the smb:// address sheet (v0.7).
    var connectSheet = false
    var connectAddress = "smb://"

    /// Find-within-folder (⌘F). v0.6: an *inline* bar (no modal) on the active
    /// pane. `searchActive` shows/hides it; `searchMode` toggles name vs content
    /// (grep); `searchRunning` drives the visible "Searching…" state so a long
    /// content scan never looks frozen.
    var searchActive = false
    var searchQuery = ""
    var searchMode: SearchMode = .name
    var searchRunning = false
    var searchHitCount = 0
    private var searchTask: Task<Void, Never>?

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
    /// Nil while enrichment is in flight; sidebar shows basic info until filled.
    var volumeClassifications: [URL: VolumeClassification] = [:]
    @ObservationIgnored private var classificationTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private let volumeCollector = VolumeInfoCollector()

    // Not observed by the UI; `nonisolated(unsafe)` lets the nonisolated deinit
    // remove the tokens. They're only mutated on the main actor during setup and
    // read in deniit when no other reference survives (H-1).
    @ObservationIgnored nonisolated(unsafe) private var volumeObservers: [NSObjectProtocol] = []

    /// Handles for the fire-and-forget tag tasks so re-entry cancels the prior
    /// run (H-2): without this, two quick tag-cloud clicks raced and the slower
    /// one's results clobbered the newer listing.
    private var openTagTask: Task<Void, Never>?
    private var refreshTagsTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?

    /// Tag cloud (§5): all known tags + per-tag file counts for the sidebar.
    var knownTags: [Tag] = []
    var tagCounts: [String: Int] = [:]

    /// Access onboarding (§6): Full Disk Access state + first-run sheet.
    var hasFullDiskAccess = true
    var showOnboarding = false
    var bannerDismissed = false
    private static let didOnboardKey = "didOnboard"

    // Bulk-rename + tag sheets driven from the UI.
    var renameSheet: Bool = false

    /// Target of the custom tag editor popover/sheet (§context menu "Tags…").
    /// Wrapped so `.sheet(item:)` has an Identifiable; nil = closed.
    struct TagSheetItem: Identifiable { let url: URL; var id: URL { url } }
    var tagSheet: TagSheetItem?

    /// Internal copy/cut buffer (distinct from NSPasteboard). Paste enqueues a
    /// copy or move into the active pane's directory.
    var clipboard: (urls: [URL], cut: Bool)?

    init() {
        let start = settings.startDirectory()
        let hidden = settings.showHiddenByDefault
        left = PaneModel(fs: fs, tags: tags, directory: start, showHidden: hidden, git: gitService)
        right = PaneModel(fs: fs, tags: tags, directory: start, showHidden: hidden, git: gitService)
        bookmarks = AppState.defaultBookmarks()
    }

    var activePane: PaneModel { activePaneIsLeft ? left : right }
    var inactivePane: PaneModel { activePaneIsLeft ? right : left }
    var activeTab: TabModel { activePane.active }

    func switchPane() { activePaneIsLeft.toggle() }

    /// Open a URL in a fresh tab of the active pane (sidebar "Open in New Tab").
    func openInNewTab(_ url: URL) { activePane.newTab(at: url) }

    // MARK: Favorites (sidebar)

    func addBookmark(_ url: URL) {
        guard !bookmarks.contains(where: { $0.path == url.path }) else { return }
        let name = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
        bookmarks.append(Bookmark(name: name, path: url.path))
    }

    func removeBookmark(_ bm: Bookmark) {
        bookmarks.removeAll { $0.id == bm.id }
    }

    func start() {
        left.active.load()
        right.active.load()
        refreshVolumes()
        observeVolumes()
        indexTagsInBackground()
        checkAccess()
        loadPlugins()
    }

    // MARK: Plugins (v0.3 Platform)

    /// Install the bundled example on first run, then load every `.js` in the
    /// plugins folder and register their columns. Reloadable from Settings.
    func loadPlugins() {
        guard let dir = JSPluginHost.defaultPluginsDirectory() else { return }
        installBundledPluginsIfNeeded(into: dir)

        // Wire app-layer handlers so JS plugins can trigger macOS system actions.
        pluginHost.openInAppHandler = { url, bundleId in
            // C-1: executable files require explicit user confirmation — same gate
            // as openFile() — so a plugin can't silently run code via Terminal/osascript.
            let dangerousExts: Set<String> = ["sh", "command", "scpt", "applescript",
                                               "workflow", "tool", "action", "pkg", "mpkg"]
            if dangerousExts.contains(url.pathExtension.lowercased()) {
                let alert = NSAlert()
                alert.messageText = "Open potentially unsafe file?"
                alert.informativeText = "\"\(url.lastPathComponent)\" may run code on your Mac. A plugin requested this action."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Open Anyway")
                alert.alertStyle = .warning
                guard alert.runModal() == .alertSecondButtonReturn else { return }
            }
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
            NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                    configuration: .init(), completionHandler: nil)
        }
        pluginHost.copyToClipboardHandler = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        pluginHost.copyPathHandler = { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
        pluginHost.readEXIFHandler = Self.readEXIF(from:)

        registry.removePluginColumns(idPrefix: JSPluginHost.columnIDPrefix)
        pluginValueCache.invalidate()   // stale async values must not survive a reload
        pluginHost.disabledIDs = disabledPluginIDs   // user toggles in Settings
        for column in pluginHost.loadPlugins(from: dir) {
            registry.register(pluginColumn: column)
        }
    }

    /// Reads EXIF/IPTC metadata from an image URL using ImageIO (no pixel decode).
    private static func readEXIF(from url: URL) -> [String: Any]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // For multi-image HEIF containers (e.g. Sony .HIF) CGImageSourceCopyPropertiesAtIndex
        // at index 0 may return nil — fall back to container-level properties.
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
                  ?? CGImageSourceCopyProperties(src, nil)) as? [String: Any]
        guard let props else { return nil }

        var result: [String: Any] = [:]
        if let w = props[kCGImagePropertyPixelWidth as String]  { result["width"]  = w }
        if let h = props[kCGImagePropertyPixelHeight as String] { result["height"] = h }

        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let d   = exif[kCGImagePropertyExifDateTimeOriginal as String] { result["dateOriginal"] = d }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first { result["iso"] = iso }
            if let f   = exif[kCGImagePropertyExifFocalLength as String]    { result["focalLength"] = f }
            if let fn  = exif[kCGImagePropertyExifFNumber as String]        { result["fNumber"] = fn }
            if let exp = exif[kCGImagePropertyExifExposureTime as String]   { result["exposureTime"] = exp }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            if let make  = tiff[kCGImagePropertyTIFFMake as String]  as? String { result["make"]  = make }
            if let model = tiff[kCGImagePropertyTIFFModel as String] as? String { result["model"] = model }
        }
        // GPS coordinates excluded: a plugin with read:exif + contribute:action
        // could silently copy location data to the clipboard without explicit consent.
        // A future read:exif:gps capability will gate this separately.
        return result.isEmpty ? nil : result
    }

    /// Plugins present on disk (enabled or not) for Settings ▸ Plugins, each with
    /// its manifest (nil = compute-only `.js`) and current enable state.
    func availablePlugins() -> [(id: String, name: String, manifest: PluginManifest?, enabled: Bool)] {
        guard let dir = JSPluginHost.defaultPluginsDirectory() else { return [] }
        return pluginHost.discoverPlugins(in: dir).map {
            ($0.id, $0.name, $0.manifest, !disabledPluginIDs.contains($0.id))
        }
    }

    /// Enable/disable a plugin by id; persists and reloads so columns/commands
    /// appear or vanish immediately.
    func setPlugin(_ id: String, enabled: Bool) {
        if enabled { disabledPluginIDs.remove(id) } else { disabledPluginIDs.insert(id) }
        UserDefaults.standard.set(Array(disabledPluginIDs), forKey: "disabledPlugins")
        loadPlugins()
    }

    /// Seed bundled plugins into the plugins folder. Each plugin is checked
    /// individually so new plugins land on existing installations without
    /// overwriting user-modified files.
    private func installBundledPluginsIfNeeded(into dir: URL) {
        func missing(_ name: String) -> Bool {
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
        }
        func write(_ content: String, to name: String) {
            try? content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // example-kind: seed only when the folder is empty (first run).
        let installed = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if !installed.contains(where: { $0.hasSuffix(".js") }) {
            write(JSPluginHost.exampleColumnPlugin, to: "example-kind.js")
        }
        // Capability plugins: seed individually, ship disabled.
        if missing("git-branch.js") {
            write(JSPluginHost.gitBranchPlugin,    to: "git-branch.js")
            write(JSPluginHost.gitBranchManifest,  to: "git-branch.json")
            disabledPluginIDs.insert("com.yafm.git-branch")
        }
        if missing("open-with.js") {
            write(JSPluginHost.openWithPlugin,     to: "open-with.js")
            write(JSPluginHost.openWithManifest,   to: "open-with.json")
            disabledPluginIDs.insert("com.yafm.open-with")
        }
        if missing("exif-info.js") {
            write(JSPluginHost.exifInfoPlugin,     to: "exif-info.js")
            write(JSPluginHost.exifInfoManifest,   to: "exif-info.json")
            disabledPluginIDs.insert("com.yafm.exif-info")
        }
        UserDefaults.standard.set(Array(disabledPluginIDs), forKey: "disabledPlugins")
    }

    /// Open the plugins folder in Finder (Settings affordance).
    func revealPluginsFolder() {
        guard let dir = JSPluginHost.defaultPluginsDirectory() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    // MARK: Search (v0.3 Platform)

    /// Find-within-folder: search the active tab's directory and show the hits as
    /// a virtual listing (like the tag cloud). Spotlight with our own fallback.
    func runSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let dir = activeTab.directory
        let tab = activeTab
        let mode = searchMode
        searchTask?.cancel()
        searchRunning = true
        searchHitCount = 0
        let label = mode == .content ? "Contents: \(q)" : "Search: \(q)"
        tab.beginVirtual(title: label, origin: dir)
        searchTask = Task { [weak self] in
            guard let self else { return }
            var entries: [FSEntry] = []
            // Consume the stream: each hit arrives as it's found, so results fill
            // progressively and cancellation (a new search / Esc) stops the walk.
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

    /// Open an `smb://` (or any) address in the active pane. The router sends it
    /// to the SMB provider, which mounts natively and streams like a folder; a
    /// failed connect shows as a `.failed` listing (the unified state-view), not
    /// a freeze. nil/garbage addresses are ignored.
    func connectToServer(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else { return }
        connectSheet = false
        activeTab.open(url)
    }

    /// Cancel an in-flight search and hide the inline bar.
    func cancelSearch() {
        searchTask?.cancel()
        searchRunning = false
        searchActive = false
    }

    // MARK: Share / AirDrop (v0.3 Platform)

    /// Share services available for a selection (includes AirDrop when reachable).
    func sharingServices(for urls: [URL]) -> [NSSharingService] {
        NSSharingService.sharingServices(forItems: urls)
    }

    func share(_ urls: [URL], with service: NSSharingService) {
        guard !urls.isEmpty else { return }
        service.perform(withItems: urls)
    }

    /// Show the system share picker on demand (so the row menu doesn't enumerate
    /// share services for every row up front — that was a big-folder freeze).
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

        // Cancel and drop enrichment for unmounted volumes.
        for url in prev.subtracting(curr) {
            classificationTasks[url]?.cancel()
            classificationTasks.removeValue(forKey: url)
            volumeClassifications.removeValue(forKey: url)
        }

        // Enrich new (or not-yet-classified) volumes off the main actor.
        for vol in volumes where volumeClassifications[vol.url] == nil
                              && classificationTasks[vol.url] == nil {
            let collector = volumeCollector   // capture struct value, Sendable
            let v = vol
            classificationTasks[vol.url] = Task.detached { [weak self] in
                let c = collector.collect(volume: v)
                guard !Task.isCancelled, let self else { return }
                await MainActor.run { self.volumeClassifications[v.url] = c }
            }
        }
    }

    /// Live updates: NSWorkspace posts mount/unmount on the main thread, so the
    /// closures touch main-actor state directly.
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
                // Hop to the main actor explicitly rather than asserting it —
                // robust under Swift 6 even if the queue contract changes (H-3).
                Task { @MainActor in self?.refreshVolumes() }
            }
            volumeObservers.append(token)
        }
    }

    deinit {
        // Tokens were registered on NSWorkspace's notification center; removing
        // them is thread-safe, so this is fine from a nonisolated deinit (H-1).
        let nc = NSWorkspace.shared.notificationCenter
        for token in volumeObservers { nc.removeObserver(token) }
        for task in classificationTasks.values { task.cancel() }
    }

    func eject(_ volume: Volume) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
        } catch {
            NSAlert(error: error).runModal()
        }
        refreshVolumes()
    }

    // MARK: Tag cloud (§5)

    /// Refresh the sidebar tag cloud: known tags + per-tag counts.
    func refreshTags() {
        refreshTagsTask?.cancel()
        refreshTagsTask = Task { [weak self] in
            guard let self else { return }
            let all = await self.tags.allKnownTags()
            if Task.isCancelled { return }
            var counts: [String: Int] = [:]
            for t in all { counts[t.name] = await self.tags.entries(taggedWith: t).count }
            if Task.isCancelled { return }
            self.knownTags = all
            self.tagCounts = counts
        }
    }

    /// Load the persisted index, populate from Home in the background so the
    /// cloud isn't empty on a cold start, refresh the sidebar, then persist.
    private func indexTagsInBackground() {
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            guard let self else { return }
            await self.tags.loadPersisted()
            self.refreshTags()   // show whatever persisted immediately
            await self.tags.index(roots: [FileManager.default.homeDirectoryForCurrentUser])
            if Task.isCancelled { return }
            self.refreshTags()
            await self.tags.persist()
        }
    }

    /// Settings → Tags → Rescan: rebuild the index from Home, refresh, persist.
    func rescanTags() {
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            guard let self else { return }
            await self.tags.index(roots: [FileManager.default.homeDirectoryForCurrentUser])
            if Task.isCancelled { return }
            self.refreshTags()
            await self.tags.persist()
        }
    }

    /// Settings → Tags → Clear: drop the in-memory index (xattrs untouched).
    func clearTags() {
        Task { [weak self] in
            guard let self else { return }
            await self.tags.clear()
            self.refreshTags()
        }
    }

    /// Tag manager (Settings → Tags): rename / delete / recolor a tag across
    /// every file that carries it, then persist, refresh the cloud, and reload
    /// the visible listing so the change shows immediately.
    func renameTag(_ old: String, to new: String) {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.tags.renameTag(old, to: new)
            await self.tags.persist()
            self.refreshTags()
            self.activeTab.load()
        }
    }

    func deleteTag(_ name: String) {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.tags.deleteTag(name)
            await self.tags.persist()
            self.refreshTags()
            self.activeTab.load()
        }
    }

    func recolorTag(_ name: String, colorIndex: Int?) {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.tags.recolorTag(name, colorIndex: colorIndex)
            await self.tags.persist()
            self.refreshTags()
            self.activeTab.load()
        }
    }

    /// NSAlert prompt to rename a tag (Settings affordance).
    func promptRenameTag(_ tag: Tag) {
        let alert = NSAlert()
        alert.messageText = "Rename Tag"
        alert.informativeText = "Rename \"\(tag.name)\" on every file that carries it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = tag.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != tag.name else { return }
        renameTag(tag.name, to: new)
    }

    /// Confirm + delete a tag from every file.
    func promptDeleteTag(_ tag: Tag) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete tag \"\(tag.name)\"?"
        alert.informativeText = "Removes it from every file that carries it (\(tagCounts[tag.name] ?? 0)). The files themselves are untouched."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteTag(tag.name)
    }

    /// Click a tag → stream every file carrying it into a virtual listing, so a
    /// large tag doesn't block on building the whole array first (was: built
    /// synchronously, no streaming). Re-entry cancels the prior open (H-2).
    func openTag(_ tag: Tag) {
        openTagTask?.cancel()
        let targetTab = activeTab
        openTagTask = Task { [weak self] in
            guard let self else { return }
            let urls = await self.tags.entries(taggedWith: tag)
            targetTab.beginVirtual(title: "Tag: \(tag.name)")
            var entries: [FSEntry] = []
            for url in urls {
                if Task.isCancelled { return }
                guard var e = try? await self.fs.metadata(of: url) else { continue }
                e.tags = await self.tags.tags(of: url)
                entries.append(e)
                // Flush in small batches so the list fills progressively.
                if entries.count % 64 == 0 { targetTab.appendVirtual(entries) }
            }
            if Task.isCancelled { return }
            targetTab.appendVirtual(entries)
        }
    }

    // MARK: Access onboarding (§6)

    /// Detect Full Disk Access by probing a TCC-protected path. Shows the
    /// first-run onboarding sheet once; the banner stays until access is granted.
    func checkAccess() {
        if !UserDefaults.standard.bool(forKey: Self.didOnboardKey) {
            showOnboarding = true
        }
        // PERF: the TCC probe does a synchronous open() that can stall on a slow
        // home dir — run it off the main actor and apply the result back (P2-10).
        Task { [weak self] in
            let granted = await Task.detached(priority: .userInitiated) { AppState.hasFullDiskAccess() }.value
            self?.hasFullDiskAccess = granted
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.didOnboardKey)
        showOnboarding = false
    }

    /// Open System Settings → Privacy & Security → Full Disk Access.
    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFilesAccess") {
            NSWorkspace.shared.open(url)
        }
    }

    /// FDA can't be queried directly — probe a TCC-protected file. A readable
    /// `TCC.db` means access is granted; EPERM means it isn't.
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
        case CommandID.refresh: activeTab.load()
        case CommandID.quickLook, CommandID.view: QuickLook.toggle(urls: activeTab.actionable.map(\.url))
        case CommandID.edit: editCursor()
        case CommandID.search:
            // Toggle the inline bar; opening it focuses the field (handled in the
            // view). A second ⌘F while open closes it and any running search.
            if searchActive { cancelSearch() } else { searchActive = true }
        case CommandID.commandPalette: commandPalette = true
        case CommandID.cheatSheet: cheatSheet = true
        case CommandID.connectServer: connectAddress = "smb://"; connectSheet = true
        case CommandID.nextTab: activePane.cycleTab(by: 1)
        case CommandID.prevTab: activePane.cycleTab(by: -1)
        // JS-contributed commands (v0.8) dispatch to the host by id prefix.
        case let cmd where cmd.hasPrefix(JSPluginHost.commandIDPrefix):
            pluginHost.runCommand(cmd)
        default: break
        }
    }

    /// JS plugin commands for the palette / pane menu (v0.8).
    func pluginCommands() -> [(id: String, title: String)] {
        pluginHost.commands.map { ($0.id, $0.title) }
    }

    /// JS plugin context-menu items; running one targets the given entry.
    func pluginMenuItems() -> [(id: String, title: String)] {
        pluginHost.menuItems.map { ($0.id, $0.title) }
    }

    func runPluginMenuItem(_ id: String, on entry: FSEntry) {
        pluginHost.runMenuItem(id, on: entry)
    }

    /// `allowFileOpen: false` makes the action enter folders only and ignore
    /// files — that's the → (right arrow) default, gated by the setting.
    func openCursor(allowFileOpen: Bool = true) {
        guard let entry = activeTab.actionable.first ?? activeTab.displayed.first(where: { $0.url == activeTab.cursor }) else { return }
        if entry.isDirectory { activeTab.open(entry.url) }
        else if entry.url.isFileURL, entry.url.pathExtension.lowercased() == "zip" { browseArchive(entry.url) }
        else if allowFileOpen { openFile(entry.url) }
    }

    /// Open a `.zip` as a read-only browsable archive in the active tab (v0.8).
    func browseArchive(_ zip: URL) {
        guard let url = ArchiveLocation.url(zip: zip, inner: "") else { return }
        activeTab.open(url)
    }

    /// → key: enter folders always; open files only if the setting allows it.
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
                self?.forgetTagged(sources)   // sources left their old paths
                self?.activeTab.load()
            }
        }
    }

    /// Drag-and-drop landing (v0.5): copy (or move, when ⌘ is held) explicit
    /// source URLs into `destination`. Distinct from `enqueue`, which derives
    /// sources from the active selection — a drop carries its own payload and a
    /// target folder that may not be the active pane. No-ops a self-drop (source
    /// already in destination) and a drop of a folder onto itself.
    func dropEntries(_ sources: [URL], onto destination: URL, move: Bool) {
        let dest = destination.standardizedFileURL
        let filtered = sources.map { $0.standardizedFileURL }.filter { src in
            src != dest                                            // onto itself
            && src.deletingLastPathComponent().standardizedFileURL != dest  // already here
        }
        guard !filtered.isEmpty else { return }
        let task = OperationTask(kind: move ? .move : .copy, sources: filtered,
                                 destination: dest, collision: settings.collisionDefault)
        runTask(task) { [weak self] in
            guard let self else { return }
            // Reload any visible tab showing the destination or a moved-from dir.
            let touched = Set([dest] + (move ? filtered.map { $0.deletingLastPathComponent().standardizedFileURL } : []))
            for pane in [self.left, self.right] {
                if touched.contains(pane.active.directory.standardizedFileURL) { pane.active.load() }
            }
            if move { self.forgetTagged(filtered) }
        }
    }

    /// Move to Trash (recoverable) — the default destructive action (F8). No
    /// confirm needed since it's undoable from Finder's Trash.
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
            forgetTagged(trashed)
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
            self?.forgetTagged(sources)   // deleted paths must leave the index
            self?.activeTab.load()
        }
    }

    /// Drop moved/renamed/deleted URLs from the tag index so the cloud counts and
    /// "everything tagged X" listings don't point at paths that no longer exist.
    private func forgetTagged(_ urls: [URL]) {
        Task { [weak self] in
            guard let self else { return }
            for url in urls { await self.tags.forget(url) }
            self.refreshTags()
        }
    }

    func rename(to newName: String) {
        guard let entry = activeTab.actionable.first, !newName.isEmpty else { return }
        rename(entry: entry, to: newName)
    }

    func rename(entry: FSEntry, to newName: String) {
        // Must be a plain leaf name — reject path traversal ("../etc/passwd").
        guard !newName.isEmpty, !newName.contains("/"), newName != ".", newName != ".." else { return }
        let task = OperationTask(kind: .rename(to: newName), sources: [entry.url])
        runTask(task) { [weak self] in
            self?.forgetTagged([entry.url])   // the old leaf name is gone
            self?.activeTab.load()
        }
    }

    /// Open a file in its default app, confirming first for executable/script
    /// types (this app is non-sandboxed with full disk access).
    func openFile(_ url: URL) {
        let risky: Set<String> = ["sh", "command", "zsh", "bash", "scpt", "workflow", "app", "term", "tool"]
        if risky.contains(url.pathExtension.lowercased()) {
            let alert = NSAlert()
            alert.messageText = "Open \"\(url.lastPathComponent)\"?"
            alert.informativeText = "This may run code on your Mac."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        NSWorkspace.shared.open(url)
    }

    /// F4 Edit — open the cursor file in its default app for editing. (A
    /// user-assignable editor comes later; for now this is the system handler.)
    func editCursor() {
        guard let entry = activeTab.actionable.first, !entry.isDirectory else { return }
        NSWorkspace.shared.open(entry.url)
    }

    // MARK: Context-menu commands (v0.2.1)

    /// Right-clicking a row outside the current selection acts on that row only.
    /// Mirror Finder: focus it (and its pane) before the menu's items run.
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
        // Consume a cut immediately so a second ⌘V can't double-move it (H-6);
        // the clipboard isn't needed once the task is enqueued.
        if clip.cut { clipboard = nil }
        let task = OperationTask(kind: clip.cut ? .move : .copy, sources: clip.urls, destination: dest,
                                 collision: settings.collisionDefault)
        runTask(task) { [weak self] in
            if clip.cut { self?.forgetTagged(clip.urls) }   // moved out of source
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
        // Reject empty + path traversal — must be a plain leaf name.
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return }
        let url = parent.appendingPathComponent(name, isDirectory: true)
        do {
            // Route mkdir through the engine so all mutating FS work lives in
            // one place rather than calling FileManager directly from the UI.
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

    /// Application handlers for a file, from LaunchServices (macOS 12+).
    func applications(for url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    func openFile(_ url: URL, withApplication appURL: URL) {
        // Surface launch failures instead of swallowing them (H-5).
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Task { @MainActor in NSAlert(error: error).runModal() }
        }
    }

    /// "Other…" — pick an app from /Applications and open the file with it.
    func openWithOther(_ url: URL) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let app = panel.url else { return }
        openFile(url, withApplication: app)
    }

    // MARK: Tags (color toggles + free tag; full editor in §5)

    func toggleColorTag(name: String, colorIndex: Int, on entry: FSEntry) {
        Task { [weak self] in
            guard let self else { return }
            var current = await self.tags.tags(of: entry.url)
            if let i = current.firstIndex(where: { $0.name == name }) {
                current.remove(at: i)
            } else {
                current.append(Tag(name: name, colorIndex: colorIndex))
            }
            try? await self.tags.setTags(current, on: entry.url)
            self.activeTab.load()
            self.refreshTags()
        }
    }

    func addTag(_ name: String, on entry: FSEntry) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return }
        Task { [weak self] in
            guard let self else { return }
            var current = await self.tags.tags(of: entry.url)
            guard !current.contains(where: { $0.name == trimmed }) else { return }
            current.append(Tag(name: trimmed))
            try? await self.tags.setTags(current, on: entry.url)
            self.activeTab.load()
            self.refreshTags()
        }
    }

    /// Persist a full tag set for one URL (the custom tag editor writes the whole
    /// array on every change), then refresh the list + sidebar cloud.
    func writeTags(_ newTags: [Tag], on url: URL) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.tags.setTags(newTags, on: url)
            self.activeTab.load()
            self.refreshTags()
        }
    }

    func currentTags(of url: URL) async -> [Tag] { await tags.tags(of: url) }

    func promptNewTag(on entry: FSEntry) {
        let alert = NSAlert()
        alert.messageText = "New Tag"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        addTag(field.stringValue, on: entry)
    }

    // MARK: Sort (driven from background menu + column headers in §4)

    func sortBy(_ key: SortKey) {
        var order = activeTab.sortOrder
        if order.key == key { order.ascending.toggle() }
        else { order = SortOrder(key: key, ascending: true) }
        activeTab.sortOrder = order
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
        // `cancel` is nonisolated + lock-backed, so this is observed mid-copy
        // instead of queueing behind the running operation (B-2).
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
