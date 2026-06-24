import Foundation

// MARK: - Commands & keybindings

/// A key plus modifiers, expressed without importing AppKit so Core stays UI-free.
public struct KeyBinding: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        case char(Character)
        case function(Int)            // F1...F12
        case tab, space, enter, delete, escape
        case up, down, left, right
    }
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift   = Modifiers(rawValue: 1 << 1)
        public static let option  = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }
    public let key: Key
    public let modifiers: Modifiers
    public init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// A user-invokable action. One registry drives keybindings now and the
/// command palette (⌘K) later — adding a feature = registering a command.
public struct Command: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let defaultKey: KeyBinding?
    public init(id: String, title: String, defaultKey: KeyBinding? = nil) {
        self.id = id
        self.title = title
        self.defaultKey = defaultKey
    }
}

/// Stable identifiers for the built-in TC-style commands.
public enum CommandID {
    public static let open = "nav.open"
    public static let goUp = "nav.up"
    public static let switchPane = "nav.switchPane"
    public static let copy = "op.copy"
    public static let move = "op.move"
    public static let delete = "op.delete"
    public static let rename = "op.rename"
    public static let toggleHidden = "view.toggleHidden"
    public static let quickLook = "view.quickLook"
    public static let newTab = "tab.new"
    public static let closeTab = "tab.close"
    public static let togglePreview = "view.togglePreview"
    // v0.2.1 context-menu commands
    public static let clipCopy = "op.clipCopy"     // ⌘C -> internal clipboard
    public static let clipCut = "op.clipCut"       // ⌘X -> internal clipboard
    public static let paste = "op.paste"           // ⌘V <- internal clipboard
    public static let newFolder = "op.newFolder"   // F7
    public static let reveal = "nav.reveal"        // Reveal in Finder
    public static let copyPath = "op.copyPath"
    public static let getInfo = "view.getInfo"     // ⌘I (info panel, §4)
    public static let refresh = "view.refresh"     // ⌘R
    public static let view = "view.view"           // F3 QuickLook
    public static let edit = "op.edit"             // F4 open in editor
    // v0.3 platform commands
    public static let search = "view.search"       // ⌘F find within the folder
    public static let editPath = "nav.editPath"    // ⌘L focus the path bar to type a path
    public static let undo = "edit.undo"           // ⌘Z reverse the last file operation
    public static let compareFolders = "view.compare" // diff the two panes by name/size/mtime
    public static let extractArchive = "op.extract"  // unpack the selected archive here
    public static let compressSelection = "op.compress" // zip the selection
    // v0.4 keyboard-first commands
    public static let commandPalette = "app.palette" // ⌘K fuzzy jump-to-anything
    public static let cheatSheet = "help.shortcuts"  // ⌘/ shortcut overlay
    public static let nextTab = "tab.next"           // ⌃Tab
    public static let prevTab = "tab.prev"           // ⌃⇧Tab
    // v0.7 reach
    public static let connectServer = "nav.connectServer" // ⌘K-reachable: mount smb://
    // v0.9.1 UX
    public static let selectAll = "sel.all"           // ⌘A
    public static let invertSelection = "sel.invert"  // palette/menu
    public static let toggleSelect = "sel.toggle"     // Insert — toggle + advance
    public static let deletePermanent = "op.deletePermanent" // ⇧F8 (F8 = Trash)
    public static let trash = "op.trash"              // F8 → move to Trash
    // v0.9.6 layout
    public static let toggleSidebar = "view.toggleSidebar" // ⌘⌥S
}

/// The default Total Commander-style bindings.
public enum DefaultCommands {
    public static let all: [Command] = [
        Command(id: CommandID.open, title: "Open", defaultKey: KeyBinding(.enter)),
        Command(id: CommandID.goUp, title: "Go Up", defaultKey: KeyBinding(.delete)),
        Command(id: CommandID.switchPane, title: "Switch Pane", defaultKey: KeyBinding(.tab)),
        Command(id: CommandID.copy, title: "Copy", defaultKey: KeyBinding(.function(5))),
        Command(id: CommandID.move, title: "Move", defaultKey: KeyBinding(.function(6))),
        Command(id: CommandID.delete, title: "Delete"),   // F8 now = Move to Trash; this stays menu-only (permanent)
        Command(id: CommandID.rename, title: "Rename", defaultKey: KeyBinding(.function(2))),
        Command(id: CommandID.toggleHidden, title: "Toggle Hidden Files", defaultKey: KeyBinding(.char("."), [.command, .shift])),
        Command(id: CommandID.quickLook, title: "Quick Look", defaultKey: KeyBinding(.space)),
        Command(id: CommandID.newTab, title: "New Tab", defaultKey: KeyBinding(.char("t"), [.command])),
        Command(id: CommandID.closeTab, title: "Close Tab", defaultKey: KeyBinding(.char("w"), [.command])),
        Command(id: CommandID.togglePreview, title: "Toggle Preview", defaultKey: KeyBinding(.char("p"), [.command, .shift])),
        Command(id: CommandID.clipCopy, title: "Copy", defaultKey: KeyBinding(.char("c"), [.command])),
        Command(id: CommandID.clipCut, title: "Cut", defaultKey: KeyBinding(.char("x"), [.command])),
        Command(id: CommandID.paste, title: "Paste", defaultKey: KeyBinding(.char("v"), [.command])),
        Command(id: CommandID.newFolder, title: "New Folder", defaultKey: KeyBinding(.function(7))),
        Command(id: CommandID.reveal, title: "Reveal in Finder"),
        Command(id: CommandID.copyPath, title: "Copy Path", defaultKey: KeyBinding(.char("c"), [.command, .shift])),
        Command(id: CommandID.getInfo, title: "Get Info", defaultKey: KeyBinding(.char("i"), [.command])),
        Command(id: CommandID.refresh, title: "Refresh", defaultKey: KeyBinding(.char("r"), [.command])),
        Command(id: CommandID.view, title: "View", defaultKey: KeyBinding(.function(3))),
        Command(id: CommandID.edit, title: "Edit", defaultKey: KeyBinding(.function(4))),
        Command(id: CommandID.search, title: "Search", defaultKey: KeyBinding(.char("f"), [.command])),
        Command(id: CommandID.editPath, title: "Edit Path", defaultKey: KeyBinding(.char("l"), [.command])),
        Command(id: CommandID.undo, title: "Undo", defaultKey: KeyBinding(.char("z"), [.command])),
        Command(id: CommandID.compareFolders, title: "Compare Folders"),
        Command(id: CommandID.extractArchive, title: "Extract Here"),
        Command(id: CommandID.compressSelection, title: "Compress"),
        Command(id: CommandID.commandPalette, title: "Command Palette", defaultKey: KeyBinding(.char("k"), [.command])),
        Command(id: CommandID.cheatSheet, title: "Keyboard Shortcuts", defaultKey: KeyBinding(.char("/"), [.command])),
        Command(id: CommandID.nextTab, title: "Next Tab", defaultKey: KeyBinding(.tab, [.control])),
        Command(id: CommandID.prevTab, title: "Previous Tab", defaultKey: KeyBinding(.tab, [.control, .shift])),
        Command(id: CommandID.connectServer, title: "Connect to Server…", defaultKey: KeyBinding(.char("k"), [.command, .shift])),
        Command(id: CommandID.selectAll, title: "Select All", defaultKey: KeyBinding(.char("a"), [.command])),
        Command(id: CommandID.invertSelection, title: "Invert Selection"),
        Command(id: CommandID.trash, title: "Move to Trash", defaultKey: KeyBinding(.function(8))),
        Command(id: CommandID.deletePermanent, title: "Delete Permanently", defaultKey: KeyBinding(.function(8), [.shift])),
        Command(id: CommandID.toggleSidebar, title: "Toggle Sidebar", defaultKey: KeyBinding(.char("s"), [.command, .option])),
    ]

    /// Single source of truth for key dispatch: binding → command id, derived
    /// from `all`. The keyboard layer decodes a raw event into a `KeyBinding`
    /// and looks it up here, instead of duplicating F-key codes (P1).
    public static let byBinding: [KeyBinding: String] = {
        var map: [KeyBinding: String] = [:]
        for command in all {
            if let key = command.defaultKey { map[key] = command.id }
        }
        return map
    }()
}

// MARK: - Extension registry (invisible in v0.1, but the real plugin contract)

public enum ColumnValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    case date(Date)
    case none
}

public protocol ColumnProvider: Sendable {
    var id: String { get }
    var title: String { get }
    func value(for entry: FSEntry) -> ColumnValue
}

public protocol CommandProvider: Sendable {
    var commands: [Command] { get }
}

public struct MenuItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public protocol ContextMenuProvider: Sendable {
    func items(for selection: [FSEntry]) -> [MenuItem]
}

/// A column contributed at runtime — by a JS plugin or a first-party native
/// provider. Unlike `ColumnProvider` (a `Sendable` protocol for pure value
/// types), this carries a `@MainActor` closure so it can wrap a JavaScriptCore
/// `JSValue` (not `Sendable`) or read main-actor app state (git status). The
/// table renders one trailing column per registered `PluginColumn`.
@MainActor
public struct PluginColumn: Identifiable {
    public let id: String
    public let title: String
    /// Synchronous fast path — computed on the main actor as the table builds
    /// each row. For a sync column this is the value; for an async column it is
    /// the *placeholder* shown until `evaluateAsync` resolves.
    public let evaluate: (FSEntry) -> ColumnValue
    /// Optional async path (v0.5 seam). When set, the renderer shows `evaluate`
    /// (a placeholder) immediately, then awaits this off the critical path and
    /// swaps in the result via `PluginValueCache`. A VFS column (read a remote
    /// `.zip`/SMB attribute) plugs in here without the table — or any existing
    /// sync plugin — changing. nil = purely synchronous (the v0.3/v0.4 contract).
    public let evaluateAsync: ((FSEntry) async -> ColumnValue)?
    /// When set, the column is only shown in folders that contain at least one
    /// file whose lowercase extension is in this set. nil = always visible.
    public let relevantExtensions: Set<String>?

    /// Synchronous column (back-compatible default; `evaluateAsync` stays nil).
    public init(id: String, title: String, relevantExtensions: Set<String>? = nil,
                evaluate: @escaping (FSEntry) -> ColumnValue) {
        self.id = id
        self.title = title
        self.relevantExtensions = relevantExtensions
        self.evaluate = evaluate
        self.evaluateAsync = nil
    }

    /// Async column. `placeholder` (default `.none`) renders until the first
    /// async resolve lands — keeping the never-freeze pillar: a slow value never
    /// blocks the row.
    public init(id: String, title: String, relevantExtensions: Set<String>? = nil,
                placeholder: @escaping (FSEntry) -> ColumnValue = { _ in .none },
                asyncEvaluate: @escaping (FSEntry) async -> ColumnValue) {
        self.id = id
        self.title = title
        self.relevantExtensions = relevantExtensions
        self.evaluate = placeholder
        self.evaluateAsync = asyncEvaluate
    }

    public var isAsync: Bool { evaluateAsync != nil }
}

/// Main-actor memo for async column values, keyed by (column, entry URL). The
/// table reads `value(for:in:onResolve:)` per cell: for a sync column it returns
/// the value directly; for an async column it returns the cached result, or the
/// placeholder while it kicks off a single background resolve (deduped per key)
/// that fills the cache and calls `onResolve` so the view re-renders. Without
/// the dedup, every scroll pass would respawn the same fetch.
@MainActor
public final class PluginValueCache {
    private struct Key: Hashable { let column: String; let url: URL }
    private var values: [Key: ColumnValue] = [:]
    private var inflight: Set<Key> = []
    /// Monotonically increasing token. Incremented on `invalidate()` so in-flight
    /// Tasks spawned before the reset silently discard their results (B1 race fix).
    private var generation = 0

    public init() {}

    /// Resolve a cell value. `onResolve` fires (on the main actor) once an async
    /// value lands, so the caller can invalidate the row.
    public func value(for entry: FSEntry, in column: PluginColumn,
                      onResolve: @escaping () -> Void) -> ColumnValue {
        let key = Key(column: column.id, url: entry.url)
        if let cached = values[key] { return cached }
        // PERF (P0-A): a sync column ran its JS `evaluate` for every row on every
        // render. Cache the first result by (column, url) — content is fixed for
        // a listing, so later renders are a dict hit, not a JSC round-trip.
        guard let async = column.evaluateAsync else {
            let v = column.evaluate(entry)
            values[key] = v
            return v
        }
        if !inflight.contains(key) {
            inflight.insert(key)
            let gen = generation   // capture before the task; guards against reload race
            Task { @MainActor in
                let resolved = await async(entry)
                guard gen == self.generation else { return }   // stale after invalidate — discard
                self.values[key] = resolved
                self.inflight.remove(key)
                onResolve()
            }
        }
        return column.evaluate(entry)   // placeholder until the resolve lands
    }

    /// Forget cached values for a column (plugin reload) or everything (nil).
    public func invalidate(columnID: String? = nil) {
        generation &+= 1   // invalidate in-flight tasks from the previous generation
        if let id = columnID {
            values = values.filter { $0.key.column != id }
            inflight = inflight.filter { $0.column != id }
        } else {
            values.removeAll()
            inflight.removeAll()
        }
    }
}

// MARK: - Plugin capability boundary (design-ahead for the v0.3 JS loader)

/// The vetted surface a plugin (column/command/menu provider) is allowed to
/// touch. Providers get a `PluginContext`, never a raw `FSEntry.url`, so that
/// when JS plugins arrive they can't read/write arbitrary paths — every FS
/// access is funnelled through here and scoped to `roots`. (ARCHITECTURE.md:143;
/// the app is non-sandboxed, so path-traversal must not be plugin-reachable.)
///
/// v0.2: first-party providers still receive `FSEntry` directly; this type
/// establishes the contract the JS host will enforce before any untrusted code
/// runs. `resolve(_:)` is the single chokepoint a future host vets against.
public struct PluginContext: Sendable {
    /// Directories a plugin may read within. Empty = no filesystem access.
    public let roots: [URL]

    public init(roots: [URL]) {
        self.roots = roots.map { $0.standardizedFileURL }
    }

    /// Resolve a plugin-supplied path, refusing anything that escapes `roots`
    /// (via `..`, symlinks, or absolute paths outside scope). nil = denied.
    public func resolve(_ path: String) -> URL? {
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let target = candidate.resolvingSymlinksInPath().path
        for root in roots {
            let base = root.resolvingSymlinksInPath().path
            // SECURITY: return the *symlink-resolved* URL, not the candidate — a
            // mid-path symlink inside the root could otherwise reach outside it
            // (O_NOFOLLOW only guards the leaf). Caller opens the real path.
            if target == base || target.hasPrefix(base + "/") { return URL(fileURLWithPath: target) }
        }
        return nil
    }
}

/// First-party features register here now; the JS loader plugs into the same
/// registry in v0.3. `@MainActor` because the UI reads it directly.
@MainActor
public final class ExtensionRegistry {
    public private(set) var columns: [ColumnProvider] = []
    public private(set) var commandProviders: [CommandProvider] = []
    public private(set) var contextMenus: [ContextMenuProvider] = []
    /// Runtime columns from JS plugins + native first-party providers (git).
    /// The file table renders one trailing column per entry here.
    public private(set) var pluginColumns: [PluginColumn] = []
    /// Bulk-rename transformers + custom previewers (v0.9 extension points).
    public private(set) var transformers: [Transformer] = []
    public private(set) var previewers: [Previewer] = []

    public init() {
        // Seed the built-in transformers/previewers; first-party features and
        // (later) plugins append more.
        transformers = [LowercaseTransformer(), SequenceTransformer(), SpaceReplaceTransformer()]
        previewers = [TextPreviewer()]
    }

    public func register(column: ColumnProvider) { columns.append(column) }
    public func register(commands: CommandProvider) { commandProviders.append(commands) }
    public func register(contextMenu: ContextMenuProvider) { contextMenus.append(contextMenu) }
    public func register(pluginColumn: PluginColumn) { pluginColumns.append(pluginColumn) }
    public func register(transformer: Transformer) { transformers.append(transformer) }
    public func register(previewer: Previewer) { previewers.append(previewer) }

    /// First previewer that handles `ext`, if any (UI consults this before QuickLook).
    public func previewer(forExtension ext: String) -> Previewer? {
        previewers.first { $0.canPreview(extension: ext) }
    }

    /// Drop plugin columns whose id has the given prefix (e.g. reload a plugin
    /// set). Native columns use a distinct prefix so they survive.
    public func removePluginColumns(idPrefix: String) {
        pluginColumns.removeAll { $0.id.hasPrefix(idPrefix) }
    }

    public func contextItems(for selection: [FSEntry]) -> [MenuItem] {
        contextMenus.flatMap { $0.items(for: selection) }
    }
}
