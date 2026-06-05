import SwiftUI
import Core

// MARK: - Keybinding → glyph string (App layer; Core stays UI-free)

extension KeyBinding {
    /// macOS-style shortcut glyphs, e.g. ⌘K, ⇧⌘P, F5.
    var glyphs: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case .char(let c): s += String(c).uppercased()
        case .function(let n): s += "F\(n)"
        case .tab: s += "⇥"
        case .space: s += "Space"
        case .enter: s += "↩"
        case .delete: s += "⌫"
        case .escape: s += "⎋"
        case .up: s += "↑"; case .down: s += "↓"; case .left: s += "←"; case .right: s += "→"
        }
        return s
    }
}

// MARK: - Command palette (⌘K)

/// One row in the palette: a command, a favorite, or a subfolder to jump to.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let shortcut: String
    let systemImage: String
    let run: () -> Void
}

/// Fuzzy "jump to anything": runs any command, jumps to a favorite, or opens a
/// subfolder of the current directory. The keyboard-first centerpiece of v0.4.
struct CommandPalette: View {
    @Bindable var app: AppState
    @State private var query = ""
    @State private var selected = 0
    @State private var items: [PaletteItem] = []   // built once on appear (P1-3)
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.row) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(String(localized: "Jump to a command, favorite, or folder…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { runSelected() }
                    .onChange(of: query) { _, _ in selected = 0 }
                    // Intercept Esc here so it closes the palette rather than
                    // the text field's default clear-on-escape (P2-5).
                    .onKeyPress(.escape) { app.commandPalette = false; return .handled }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            let items = filtered
            if items.isEmpty {
                Text(String(localized: "No matches"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    List(Array(items.enumerated()), id: \.element.id) { idx, item in
                        row(item, active: idx == selected)
                            .id(idx)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                            .listRowBackground(idx == selected ? Theme.Palette.selectionFill : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = idx; runSelected() }
                    }
                    .listStyle(.plain)
                    .frame(height: 360)
                    .onChange(of: selected) { _, new in proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
        .frame(width: 560)
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { app.commandPalette = false; return .handled }
        .onAppear { items = buildItems(); focused = true }
    }

    private func row(_ item: PaletteItem, active: Bool) -> some View {
        HStack(spacing: Theme.Space.row) {
            Image(systemName: item.systemImage)
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if !item.shortcut.isEmpty {
                Text(item.shortcut).font(Theme.Font.mono).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func move(_ d: Int) {
        let n = filtered.count
        guard n > 0 else { return }
        selected = max(0, min(n - 1, selected + d))
    }

    private func runSelected() {
        let items = filtered
        guard items.indices.contains(selected) else { return }
        app.commandPalette = false
        items[selected].run()
    }

    /// All candidate items: commands first, then favorites, then subfolders.
    /// Built once in `onAppear` (cached in `items`) so a large directory doesn't
    /// rebuild the list on every keystroke / observable mutation (P1-3).
    private func buildItems() -> [PaletteItem] {
        var out: [PaletteItem] = []
        for c in DefaultCommands.all {
            out.append(PaletteItem(
                id: "cmd.\(c.id)", title: c.title, subtitle: "",
                shortcut: c.defaultKey?.glyphs ?? "", systemImage: "command",
                run: { [weak app] in app?.run(c.id) }))
        }
        // Plugin-contributed commands (v0.8) so the palette's "jump to anything"
        // promise covers them too (audit UX).
        for c in app.pluginCommands() {
            out.append(PaletteItem(
                id: "pcmd.\(c.id)", title: c.title, subtitle: String(localized: "Plugin"),
                shortcut: "", systemImage: "puzzlepiece.extension",
                run: { [weak app] in app?.run(c.id) }))
        }
        for b in app.bookmarks {
            let url = URL(fileURLWithPath: b.path)
            out.append(PaletteItem(
                id: "fav.\(b.id)", title: b.name,
                subtitle: String(localized: "Favorite · \(b.path)"),
                shortcut: "", systemImage: "star",
                run: { [weak app] in app?.activeTab.open(url) }))
        }
        for e in app.activeTab.displayed where e.isDirectory {
            out.append(PaletteItem(
                id: "dir.\(e.url.path)", title: e.name,
                subtitle: String(localized: "Folder in this directory"),
                shortcut: "", systemImage: "folder",
                run: { [weak app] in app?.activeTab.open(e.url) }))
        }
        return out
    }

    /// Subsequence fuzzy filter, ranked by how early/tightly the query matches.
    /// A query that looks like a path (`/…` or `~/…`) gets a "Go to" item at the
    /// top, expanding `~` like the path bar — so ⌘K can jump anywhere by path.
    private var filtered: [PaletteItem] {
        let raw = query.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return items }
        let q = raw.lowercased()
        var results = items
            .compactMap { item -> (PaletteItem, Int)? in
                guard let score = Self.score(q, in: "\(item.title) \(item.subtitle)".lowercased()) else { return nil }
                return (item, score)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        let pitems = pathItems(for: raw)
        results.insert(contentsOf: pitems, at: 0)
        return results
    }

    /// Live path completion when the query is a path (`/…` or `~/…`): the exact
    /// folder if it exists, plus child folders whose name the typed leaf prefixes.
    /// Hidden folders (`.ssh`) stay out until the user types a leading dot — so
    /// `~/D` offers Documents/Downloads but `~/.s` is needed to reach `.ssh`.
    private func pathItems(for raw: String) -> [PaletteItem] {
        guard raw.hasPrefix("/") || raw.hasPrefix("~") else { return [] }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else { return [] }
        let fm = FileManager.default
        var out: [PaletteItem] = []

        func goItem(_ url: URL, _ title: String) -> PaletteItem {
            PaletteItem(id: "goto.\(url.path)", title: title, subtitle: url.path,
                        shortcut: "", systemImage: "folder",
                        run: { [weak app] in app?.activeTab.open(url) })
        }

        // Exact existing directory → top item, so Enter enters the typed path.
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            out.append(goItem(URL(fileURLWithPath: expanded), String(localized: "Go to \(expanded)")))
        }

        // Parent dir + partial leaf to complete against.
        let parent: String, leaf: String
        if raw.hasSuffix("/") { parent = expanded; leaf = "" }
        else { parent = (expanded as NSString).deletingLastPathComponent
               leaf = (expanded as NSString).lastPathComponent }
        let ql = leaf.lowercased()
        guard let names = try? fm.contentsOfDirectory(atPath: parent) else { return out }
        let matches = names.filter { name in
            let lower = name.lowercased()
            if name.hasPrefix(".") {                       // hidden: opt-in via dot
                return (ql.hasPrefix(".") && lower.hasPrefix(ql)) || lower == ql
            }
            return ql.isEmpty || lower.hasPrefix(ql)
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in matches.prefix(12) {
            let url = URL(fileURLWithPath: parent).appendingPathComponent(name)
            guard url.path != expanded else { continue }   // already the exact item
            var d: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &d), d.boolValue else { continue }
            out.append(goItem(url, name))
        }
        return out
    }

    /// nil = no subsequence match; lower = better (earlier first hit + tighter run).
    static func score(_ query: String, in text: String) -> Int? {
        var qi = query.startIndex
        var firstHit: Int?
        var gaps = 0, lastMatch = -2, pos = 0
        for ch in text {
            if qi < query.endIndex, ch == query[qi] {
                if firstHit == nil { firstHit = pos }
                if pos != lastMatch + 1 { gaps += 1 }
                lastMatch = pos
                qi = query.index(after: qi)
            }
            pos += 1
        }
        guard qi == query.endIndex else { return nil }
        return (firstHit ?? 0) + gaps * 4
    }
}

// MARK: - Shortcut cheat sheet (⌘/)

/// A discoverability overlay: every keyboard shortcut, grouped. Opened with ⌘/.
struct CheatSheet: View {
    @Bindable var app: AppState

    private struct Group: Identifiable { let id = UUID(); let title: String; let ids: [String] }
    private static let groups: [Group] = [
        Group(title: String(localized: "Navigation"),
              ids: [CommandID.open, CommandID.goUp, CommandID.switchPane, CommandID.nextTab, CommandID.prevTab, CommandID.newTab, CommandID.closeTab]),
        Group(title: String(localized: "Files"),
              ids: [CommandID.copy, CommandID.move, CommandID.delete, CommandID.rename, CommandID.newFolder, CommandID.clipCopy, CommandID.clipCut, CommandID.paste]),
        Group(title: String(localized: "View"),
              ids: [CommandID.quickLook, CommandID.togglePreview, CommandID.toggleHidden, CommandID.getInfo, CommandID.refresh, CommandID.view, CommandID.edit]),
        Group(title: String(localized: "Search & Palette"),
              ids: [CommandID.commandPalette, CommandID.search, CommandID.cheatSheet]),
    ]

    private static let byID: [String: Command] = {
        Dictionary(uniqueKeysWithValues: DefaultCommands.all.map { ($0.id, $0) })
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "Keyboard Shortcuts")).font(.title2.bold())
                Spacer()
                Button { app.cheatSheet = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                    GridItem(.flexible(), alignment: .topLeading)], spacing: 20) {
                    ForEach(Self.groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title).font(.headline)
                            ForEach(group.ids, id: \.self) { id in
                                if let c = Self.byID[id] {
                                    HStack {
                                        Text(c.title).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(c.defaultKey?.glyphs ?? "—").font(Theme.Font.mono)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // Behaviors without a Command entry, surfaced for discoverability.
            Divider().padding(.vertical, 10)
            VStack(alignment: .leading, spacing: 4) {
                extraRow(String(localized: "Move cursor"), "↑ ↓")
                extraRow(String(localized: "Jump to top / bottom"), "Home  End")
                extraRow(String(localized: "Page up / down"), "⇞ ⇟")
                extraRow(String(localized: "Into folder / up a level"), "→  ←")
                extraRow(String(localized: "Toggle-select & advance"), "Insert")
                extraRow(String(localized: "Extend selection"), "⇧↑ ⇧↓ · ⌘-click · ⇧-click")
                extraRow(String(localized: "Type to filter the current folder"), "A–Z 0–9")
                extraRow(String(localized: "Jump to tab 1–9"), "⌘1–⌘9")
                extraRow(String(localized: "Cheat sheet"), "⌘/")
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .onKeyPress(.escape) { app.cheatSheet = false; return .handled }
    }

    private func extraRow(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(keys).font(Theme.Font.mono)
        }
    }
}
