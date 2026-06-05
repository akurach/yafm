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
    private(set) var state: ListingState = .idle { didSet { recomputeDisplayed() } }
    var sortOrder = SortOrder() { didSet { recomputeDisplayed() } }
    var showHidden = false { didSet { recomputeDisplayed() } }

    /// Non-nil when the tab shows a virtual listing (e.g. "everything tagged X")
    /// instead of a real directory. Cleared the moment the user navigates.
    private(set) var virtualName: String?

    /// Multi-selection + the keyboard cursor (focused row).
    var selection: Set<URL> = []
    var cursor: URL?

    private var task: Task<Void, Never>?

    init(fs: FileSystemProvider, tags: TagServing, directory: URL, showHidden: Bool = false) {
        self.fs = fs
        self.tags = tags
        self.directory = directory
        self.showHidden = showHidden
    }

    var title: String {
        if let v = virtualName { return v }
        return directory.lastPathComponent.isEmpty ? "/" : directory.lastPathComponent
    }

    /// Entries after hidden-filter + sort. The single source the table renders.
    /// Cached: recomputed only when `state`/`sortOrder`/`showHidden` change, not
    /// on every access (the table read + re-sorted it per render before).
    private(set) var displayed: [FSEntry] = []

    private func recomputeDisplayed() {
        let base: [FSEntry]
        switch state {
        case .loading(let p): base = p
        case .loaded(let e): base = e
        default: base = []
        }
        let filtered = showHidden ? base : base.filter { !$0.isHidden }
        displayed = filtered.sorted(by: sortOrder)
    }

    func open(_ url: URL) {
        virtualName = nil
        directory = url
        selection = []
        cursor = nil
        load()
    }

    /// Begin a virtual listing (tag cloud, search results) — not tied to
    /// `directory`; Refresh/navigation leaves it. Entries stream in via
    /// `appendVirtual` so a large set fills progressively.
    func beginVirtual(title: String) {
        task?.cancel()
        virtualName = title
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
    /// New tabs inherit this (from `AppSettings.showHiddenByDefault`).
    private let defaultShowHidden: Bool

    init(fs: FileSystemProvider, tags: TagServing, directory: URL, showHidden: Bool = false) {
        self.fs = fs
        self.tags = tags
        self.defaultShowHidden = showHidden
        self.tabs = [TabModel(fs: fs, tags: tags, directory: directory, showHidden: showHidden)]
    }

    var active: TabModel { tabs[min(activeIndex, tabs.count - 1)] }

    func newTab(at directory: URL? = nil) {
        let dir = directory ?? active.directory
        tabs.append(TabModel(fs: fs, tags: tags, directory: dir, showHidden: defaultShowHidden))
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
    let volumeService = VolumeService()
    let settings = AppSettings()

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
    // Not observed by the UI; `nonisolated(unsafe)` lets the nonisolated deinit
    // remove the tokens. They're only mutated on the main actor during setup and
    // read in deinit when no other reference survives (H-1).
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
        left = PaneModel(fs: fs, tags: tags, directory: start, showHidden: hidden)
        right = PaneModel(fs: fs, tags: tags, directory: start, showHidden: hidden)
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
    }

    // MARK: Volumes (§2)

    func refreshVolumes() { volumes = volumeService.mountedVolumes() }

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
        hasFullDiskAccess = Self.hasFullDiskAccess()
        if !UserDefaults.standard.bool(forKey: Self.didOnboardKey) {
            showOnboarding = true
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
    static func hasFullDiskAccess() -> Bool {
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
        case CommandID.delete: enqueueDelete()
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
        default: break
        }
    }

    /// `allowFileOpen: false` makes the action enter folders only and ignore
    /// files — that's the → (right arrow) default, gated by the setting.
    func openCursor(allowFileOpen: Bool = true) {
        guard let entry = activeTab.actionable.first ?? activeTab.displayed.first(where: { $0.url == activeTab.cursor }) else { return }
        if entry.isDirectory { activeTab.open(entry.url) }
        else if allowFileOpen { openFile(entry.url) }
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

    func enqueueDelete() {
        let sources = activeTab.actionable.map(\.url)
        guard !sources.isEmpty else { return }
        if settings.confirmBeforeDelete {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = sources.count == 1
                ? "Delete “\(sources[0].lastPathComponent)”?"
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
            alert.messageText = "Open “\(url.lastPathComponent)”?"
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
