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
}

/// The default Total Commander-style bindings.
public enum DefaultCommands {
    public static let all: [Command] = [
        Command(id: CommandID.open, title: "Open", defaultKey: KeyBinding(.enter)),
        Command(id: CommandID.goUp, title: "Go Up", defaultKey: KeyBinding(.delete)),
        Command(id: CommandID.switchPane, title: "Switch Pane", defaultKey: KeyBinding(.tab)),
        Command(id: CommandID.copy, title: "Copy", defaultKey: KeyBinding(.function(5))),
        Command(id: CommandID.move, title: "Move", defaultKey: KeyBinding(.function(6))),
        Command(id: CommandID.delete, title: "Delete", defaultKey: KeyBinding(.function(8))),
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
        Command(id: CommandID.copyPath, title: "Copy Path"),
        Command(id: CommandID.getInfo, title: "Get Info", defaultKey: KeyBinding(.char("i"), [.command])),
        Command(id: CommandID.refresh, title: "Refresh", defaultKey: KeyBinding(.char("r"), [.command])),
        Command(id: CommandID.view, title: "View", defaultKey: KeyBinding(.function(3))),
        Command(id: CommandID.edit, title: "Edit", defaultKey: KeyBinding(.function(4))),
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
            if target == base || target.hasPrefix(base + "/") { return candidate }
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

    public init() {}

    public func register(column: ColumnProvider) { columns.append(column) }
    public func register(commands: CommandProvider) { commandProviders.append(commands) }
    public func register(contextMenu: ContextMenuProvider) { contextMenus.append(contextMenu) }

    public func contextItems(for selection: [FSEntry]) -> [MenuItem] {
        contextMenus.flatMap { $0.items(for: selection) }
    }
}
