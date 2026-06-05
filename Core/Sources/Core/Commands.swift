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
    ]
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
