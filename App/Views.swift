import SwiftUI
import AppKit
import Core
import UniformTypeIdentifiers

// MARK: - Color mapping (Core stays UI-free; the UI maps names -> Color)

extension Color {
    static func named(_ name: String?) -> Color? {
        switch name {
        case "Gray": return .gray
        case "Green": return .green
        case "Purple": return .purple
        case "Blue": return .blue
        case "Yellow": return .yellow
        case "Red": return .red
        case "Orange": return .orange
        default: return nil
        }
    }
}

// MARK: - Pane

struct PaneView: View {
    @Bindable var pane: PaneModel
    let isActive: Bool
    let app: AppState

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(pane: pane)
            Divider()
            PathBarView(tab: pane.active)
            // Inline find bar (⌘F) on the active pane only — replaces the modal.
            if isActive && app.searchActive {
                Divider()
                SearchBar(app: app)
            }
            Divider()
            FileTableView(tab: pane.active, app: app)
        }
        .background(isActive ? Theme.Palette.activePaneTint : Color.clear)
        .overlay(alignment: .top) {
            if isActive {
                Rectangle().fill(Theme.Palette.cursorStroke).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.activePaneIsLeft = (pane.id == app.left.id) }
    }
}

// MARK: - Tab bar

struct TabBarView: View {
    @Bindable var pane: PaneModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { idx, tab in
                    HStack(spacing: 4) {
                        Text(tab.title).lineLimit(1)
                        if pane.tabs.count > 1 {
                            Button { pane.closeTab(tab.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close tab \(tab.title)")
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(idx == pane.activeIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .onTapGesture { pane.select(tab.id) }
                }
                Button { pane.newTab() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).padding(.horizontal, 4)
                    .accessibilityLabel("New tab")
            }
            .padding(4)
        }
        .frame(height: 30)
        .background(.bar)
    }
}

// MARK: - Path bar + breadcrumbs

struct PathBarView: View {
    @Bindable var tab: TabModel
    @State private var editing = false
    @State private var typed = ""

    var body: some View {
        HStack(spacing: 4) {
            if editing {
                TextField("Path", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .onSubmit {
                        let expanded = (typed as NSString).expandingTildeInPath
                        // Reject null bytes and non-absolute input before listing.
                        if !expanded.isEmpty, !expanded.contains("\0"), expanded.hasPrefix("/") {
                            tab.open(URL(fileURLWithPath: expanded))
                        }
                        editing = false
                    }
            } else {
                breadcrumbs
                Spacer()
                Button { typed = tab.directory.path; editing = true } label: {
                    Image(systemName: "pencil")
                }.buttonStyle(.plain)
                .accessibilityLabel("Edit path")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.bar)
    }

    private var breadcrumbs: some View {
        let comps = tab.directory.pathComponents
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(comps.enumerated()), id: \.offset) { i, comp in
                    Button(comp == "/" ? "Macintosh HD" : comp) {
                        let url = URL(fileURLWithPath: "/" + comps[1...i].joined(separator: "/"))
                        tab.open(i == 0 ? URL(fileURLWithPath: "/") : url)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    if i < comps.count - 1 { Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(.tertiary) }
                }
            }
        }
    }
}

// MARK: - File table (selection + cursor + color coding + tags)

struct FileTableView: View {
    @Bindable var tab: TabModel
    @Bindable var app: AppState

    var body: some View {
        Group {
            switch tab.state {
            case .idle:
                // Never a blank pane: an idle tab still says what it is.
                ContentUnavailableView("Nothing open yet", systemImage: "folder",
                                       description: Text("Pick a folder from the sidebar or type a path above."))
            case .failed(let message):
                ContentUnavailableView("Can't open folder", systemImage: "exclamationmark.triangle", description: Text(message))
            case .loaded(let entries) where entries.isEmpty && !tab.filterActive:
                // An empty folder/result rendered *nothing* before — a quiet
                // violation of the never-freeze pillar. Say so explicitly.
                emptyView
            case .loaded(let entries) where tab.displayed.isEmpty && tab.filterActive && !entries.isEmpty:
                ContentUnavailableView.search(text: tab.filter)
            default:
                // Loading and loaded both render the same table; the "Reading…"
                // badge floats as an overlay so it never pushes the rows down
                // (that layout shift was the jerky-table jank during nav).
                rows.overlay(alignment: .top) {
                    if case .loading(let partial) = tab.state {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reading… (\(partial.count))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if tab.filterActive {
                HStack(spacing: Theme.Space.row) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(tab.filter.isEmpty ? String(localized: "Filter…") : tab.filter)
                        .font(Theme.Font.mono)
                    Text("· \(tab.displayed.count)").foregroundStyle(.secondary)
                    Text(String(localized: "⎋ clear")).font(.caption2).foregroundStyle(.tertiary)
                }
                .font(Theme.Font.badge)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 8)
            }
        }
    }

    // Fixed column widths; Name flexes. Header aligns to these. (Tokens layer.)
    private let sizeW = Theme.Col.size
    private let modW = Theme.Col.modified
    private let kindW = Theme.Col.kind
    private let gitW = Theme.Col.git
    private let pluginW = Theme.Col.plugin

    // The List is the only child and fills the pane natively; the column header
    // rides along as a pinned Section header (a plain List inside a VStack would
    // collapse to its intrinsic height and float mid-pane). Bonus: header and
    // rows share the List's insets, so columns line up.
    /// Empty-state for a loaded listing with no rows — distinguishes "no search
    /// matches" (a virtual results listing) from a genuinely empty folder. Both
    /// beat the old blank pane (the never-freeze pillar: always say what's true).
    @ViewBuilder
    private var emptyView: some View {
        if let origin = tab.virtualOrigin {
            ContentUnavailableView {
                Label(app.searchRunning ? "Searching…" : "No matches", systemImage: "magnifyingglass")
            } description: {
                Text(app.searchRunning
                     ? "Looking in \(origin.lastPathComponent.isEmpty ? "/" : origin.lastPathComponent)…"
                     : "Nothing in \(origin.lastPathComponent.isEmpty ? "/" : origin.lastPathComponent) matches “\(app.searchQuery)”.")
            }
        } else {
            ContentUnavailableView("Empty folder", systemImage: "folder",
                                   description: Text("This folder has no items."))
        }
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(tab.displayed) { entry in
                        row(entry)
                            .id(entry.url)
                            .listRowBackground(rowBackground(entry))
                            .contentShape(Rectangle())
                            // Single-tap selects INSTANTLY; double-tap opens. Both
                            // recognize independently (simultaneous) so the single
                            // doesn't stall ~0.3s waiting to rule out a double —
                            // that wait was the sluggish / dropped-click feel.
                            .onTapGesture {
                                app.activePaneIsLeft = tabBelongsToLeft()
                                let mods = NSEvent.modifierFlags
                                if mods.contains(.command) {
                                    // ⌘-click: toggle this row in/out of the selection.
                                    if tab.selection.contains(entry.url) { tab.selection.remove(entry.url) }
                                    else { tab.selection.insert(entry.url) }
                                    tab.cursor = entry.url
                                } else if mods.contains(.shift), let anchor = tab.cursor {
                                    // ⇧-click: select the contiguous range from the cursor.
                                    tab.selectRange(from: anchor, to: entry.url)
                                    tab.cursor = entry.url
                                } else {
                                    tab.cursor = entry.url
                                    tab.selection = [entry.url]
                                }
                            }
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                if entry.isDirectory { tab.open(entry.url) }
                                else if entry.url.isFileURL, entry.url.pathExtension.lowercased() == "zip" { app.browseArchive(entry.url) }
                                else { app.openFile(entry.url) }
                            })
                            // Drag out: the row's URL becomes the payload, so it
                            // drops into another pane, Finder, or any app.
                            .onDrag { dragPayload(entry) }
                            // Drop onto a folder row → copy (or move with ⌘) into
                            // it. File rows aren't drop targets. The targeted
                            // highlight lives in FolderDrop's own @State so only
                            // the hovered row re-renders — not the whole table.
                            .modifier(FolderDrop(
                                enabled: entry.isDirectory,
                                onDrop: { urls in app.dropEntries(urls, onto: entry.url, move: dropIsMove()) }
                            ))
                            .contextMenu { rowMenu(entry) }
                    }
                } header: {
                    columnHeader
                }
            }
            // One tag editor for the whole table (driven by app.tagSheet), NOT a
            // .popover per row — a per-row popover modifier is instantiated for
            // every row and beachballed large folders. Sheet needs no anchor.
            .sheet(item: $app.tagSheet) { item in
                TagEditorSheet(app: app, url: item.url)
            }
            .contextMenu { backgroundMenu() }   // empty area below the rows
            // Drop onto empty pane area → into the current directory. No
            // targeted-highlight @State here: mutating table-level state on every
            // hover re-rendered the whole list and made inter-pane drags crawl.
            .dropDestination(for: URL.self) { urls, _ in
                app.dropEntries(urls, onto: tab.directory, move: dropIsMove()); return true
            }
            // Plain (edge-to-edge) instead of .inset: denser, Finder/TC-like, and
            // it drops the rounded inset-card corners that notched the bottom.
            .listStyle(.plain)
            // Scoped animation (v0.5): suppress implicit animations while a folder
            // streams in (partial-batch inserts tore the table) and when the user
            // turns motion off — but let selection/cursor/nav glide once loaded.
            .transaction { txn in
                if tab.isStreaming || !app.settings.animations { txn.disablesAnimations = true }
            }
            .animation(app.settings.animations && !tab.isStreaming ? Theme.Motion.selection : nil, value: tab.cursor)
            .animation(app.settings.animations && !tab.isStreaming ? Theme.Motion.selection : nil, value: tab.selection)
            .onChange(of: tab.cursor) { _, new in
                guard let new else { return }
                proxy.scrollTo(new, anchor: .center)
                // Follow the cursor with QuickLook when its panel is open.
                if tab.id == app.activeTab.id {
                    QuickLook.updateIfVisible(urls: tab.actionable.map(\.url))
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 16)   // aligns with the row icon
            headerButton("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
            headerButton("Size", .size).frame(width: sizeW, alignment: .trailing)
            headerButton("Modified", .modified).frame(width: modW, alignment: .trailing)
            headerButton("Kind", .kind).frame(width: kindW, alignment: .leading)
            if !tab.gitStatus.isEmpty {
                Text("Git").frame(width: gitW, alignment: .center)
            }
            ForEach(app.registry.pluginColumns) { col in
                Text(col.title).lineLimit(1).frame(width: pluginW, alignment: .leading)
            }
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(.bar)
    }

    private func headerButton(_ title: String, _ key: SortKey) -> some View {
        Button {
            app.activePaneIsLeft = tabBelongsToLeft()
            app.sortBy(key)
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if tab.sortOrder.key == key {
                    Image(systemName: tab.sortOrder.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7))
                }
            }
        }
        .buttonStyle(.plain)
        .font(.caption.bold())
        .foregroundStyle(tab.sortOrder.key == key ? Color.accentColor : .secondary)
    }

    private func tabBelongsToLeft() -> Bool {
        app.left.tabs.contains { $0.id == tab.id }
    }

    // MARK: Drag & drop (§v0.5)

    /// Payload for dragging a row out — the row's file URL, droppable into the
    /// other pane, Finder, or any app. (SwiftUI `.onDrag` carries one provider /
    /// one item; a multi-row drag is a later refinement.)
    private func dragPayload(_ entry: FSEntry) -> NSItemProvider {
        NSItemProvider(object: entry.url as NSURL)
    }

    /// ⌘ held at drop time = move; otherwise copy (Finder's convention is the
    /// inverse, but yafm is move-on-⌘ to match its explicit F6-move muscle memory).
    private func dropIsMove() -> Bool { NSEvent.modifierFlags.contains(.command) }

    private func row(_ entry: FSEntry) -> some View {
        let density = app.settings.density
        // Tie rows to the async-plugin version so a resolved value re-renders.
        let _ = app.pluginValuesVersion
        return HStack(spacing: Theme.Space.row) {
            // Real macOS file-type icon (cached). A color-coding rule, if any,
            // now tints the name instead of the icon so the true icon shows.
            FileIconView(entry: entry)
                .frame(width: density.iconSize)
            Text(entry.name)
                .font(density.rowFont)
                .foregroundStyle(nameColor(entry))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(entry.tags, id: \.name) { tag in
                Circle().fill(Color.named(tag.colorName) ?? .secondary).frame(width: 8, height: 8)
            }
            Text(entry.isDirectory ? "--" : (entry.size.map(byteString) ?? "--"))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(width: sizeW, alignment: .trailing)
            Text(entry.modified.map(Self.dateText) ?? "--")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(width: modW, alignment: .trailing)
            Text(kindText(entry))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: kindW, alignment: .leading)
            if !tab.gitStatus.isEmpty {
                Text(tab.gitStatus[entry.url] ?? "")
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(gitColor(tab.gitStatus[entry.url]))
                    .frame(width: gitW, alignment: .center)
            }
            ForEach(app.registry.pluginColumns) { col in
                Text(pluginText(col, entry))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: pluginW, alignment: .leading)
            }
        }
        .padding(.vertical, density.rowPadding)
        // VoiceOver reads one coherent sentence per row instead of spelling out
        // each column cell; selection/cursor state is announced as a trait.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(entry))
        .accessibilityAddTraits(tab.cursor == entry.url ? .isSelected : [])
    }

    /// A spoken summary of a row: "Name, Kind, Size, tagged X, git modified".
    private func accessibilityLabel(_ entry: FSEntry) -> String {
        var parts = [entry.name, kindText(entry)]
        if !entry.isDirectory, let size = entry.size { parts.append(byteString(size)) }
        if !entry.tags.isEmpty { parts.append("tagged " + entry.tags.map(\.name).joined(separator: ", ")) }
        if let marker = tab.gitStatus[entry.url], !marker.isEmpty {
            let word = ["?": "untracked", "A": "added", "M": "modified", "D": "deleted"][marker] ?? "changed"
            parts.append("git \(word)")
        }
        return parts.joined(separator: ", ")
    }

    /// Tint a VCS marker via the tokens layer (added green, modified orange, deleted red).
    private func gitColor(_ marker: String?) -> Color { Theme.Palette.git(marker) }

    /// Render a plugin/native column value for a row. Async columns resolve via
    /// the shared cache: the placeholder shows now, the real value swaps in once
    /// the background resolve bumps `pluginValuesVersion` (read in `row`).
    private func pluginText(_ col: PluginColumn, _ entry: FSEntry) -> String {
        let value = app.pluginValueCache.value(for: entry, in: col) {
            app.pluginValuesVersion &+= 1
        }
        switch value {
        case .text(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .date(let d): return Self.dateText(d)
        case .none: return col.isAsync ? "…" : ""
        }
    }

    // PERF: a `UTType` lookup is a LaunchServices query — caching by extension
    // turns 10k per-render lookups into dictionary hits (perf P1-D).
    private static var kindCache: [String: String] = [:]
    private func kindText(_ entry: FSEntry) -> String {
        if entry.isDirectory { return "Folder" }
        let ext = entry.url.pathExtension
        if let hit = Self.kindCache[ext] { return hit }
        let text: String
        if let t = UTType(filenameExtension: ext), let d = t.localizedDescription { text = d }
        else { text = ext.isEmpty ? "Document" : ext.uppercased() }
        Self.kindCache[ext] = text
        return text
    }

    static func dateText(_ d: Date) -> String { Self.df.string(from: d) }
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
    // PERF: one shared formatter — the class method `ByteCountFormatter.string`
    // allocates a formatter per call (perf P2-E).
    private static let bcf: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()

    /// Color-coding rule tints the name (the icon now shows the real file type).
    private func nameColor(_ entry: FSEntry) -> Color {
        if let c = Color.named(app.colorCoder.colorName(for: entry)) { return c }
        return entry.isHidden ? .secondary : .primary
    }

    /// Selection is a full-width wash; the keyboard cursor is a thin accent bar
    /// down the leading edge — distinct from selection without boxing the row in
    /// a heavy ring (the v0.4 ring read as a clunky border on the focused row).
    @ViewBuilder
    private func rowBackground(_ entry: FSEntry) -> some View {
        let selected = tab.selection.contains(entry.url)
        let cursored = tab.cursor == entry.url
        HStack(spacing: 0) {
            Rectangle()
                .fill(cursored ? Theme.Palette.cursorStroke : Color.clear)
                .frame(width: Theme.cursorBarWidth)
            Rectangle()
                .fill(selected ? Theme.Palette.selectionFill
                      : cursored ? Theme.Palette.cursorFill : Color.clear)
        }
    }

    private func byteString(_ n: Int64) -> String {
        Self.bcf.string(fromByteCount: n)
    }

    // MARK: Context menus (§1)

    /// Focus the right-clicked row so the `actionable`-based commands target it.
    /// Called from each menu action (NOT from the menu builder) — building the
    /// menu must never mutate state, and SwiftUI builds row context menus eagerly,
    /// so a mutation there fired for every row and snapped selection to the last
    /// one (the "jumps to bottom / can't select / arrows dead" bug).
    private func focus(_ entry: FSEntry) {
        app.focusContextTarget(entry, in: tab)
    }

    /// Menu for a file/selection. Items carry SF Symbols and are grouped.
    @ViewBuilder
    private func rowMenu(_ entry: FSEntry) -> some View {
        Button { focus(entry); app.openCursor() } label: { Label("Open", systemImage: "arrow.up.forward.app") }
        Menu {
            ForEach(app.applications(for: entry.url), id: \.self) { appURL in
                Button(appURL.deletingPathExtension().lastPathComponent) {
                    app.openFile(entry.url, withApplication: appURL)
                }
            }
            Divider()
            Button("Other…") { app.openWithOther(entry.url) }
        } label: { Label("Open With", systemImage: "square.and.arrow.up") }
        Button { focus(entry); QuickLook.toggle(urls: tab.actionable.map(\.url)) } label: { Label("Quick Look", systemImage: "eye") }

        Divider()
        Button { focus(entry); app.run(CommandID.copy) } label: { Label("Copy to other pane", systemImage: "arrow.right.doc.on.clipboard") }
        Button { focus(entry); app.run(CommandID.move) } label: { Label("Move to other pane", systemImage: "arrow.right.square") }
        Button { focus(entry); app.run(CommandID.clipCopy) } label: { Label("Copy", systemImage: "doc.on.doc") }
        Button { focus(entry); app.run(CommandID.clipCut) } label: { Label("Cut", systemImage: "scissors") }

        Divider()
        Button { focus(entry); app.run(CommandID.rename) } label: { Label("Rename…", systemImage: "pencil") }
        Button { focus(entry); app.run(CommandID.newFolder) } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
        Button { focus(entry); app.run(CommandID.trash) } label: { Label("Move to Trash", systemImage: "trash") }
        Button(role: .destructive) { focus(entry); app.run(CommandID.delete) } label: { Label("Delete Permanently…", systemImage: "trash.slash") }

        Divider()
        Button { focus(entry); app.tagSheet = .init(url: entry.url) } label: {
            Label("Tags…", systemImage: "tag")
        }
        shareMenu(entry)

        if entry.isDirectory {
            Divider()
            Button { app.addBookmark(entry.url) } label: { Label("Add to Favorites", systemImage: "star") }
        }

        // JS plugin context-menu items (v0.8), gated by the plugin's manifest.
        let pluginItems = app.pluginMenuItems()
        if !pluginItems.isEmpty {
            Divider()
            ForEach(pluginItems, id: \.id) { item in
                Button { focus(entry); app.runPluginMenuItem(item.id, on: entry) } label: {
                    Label(item.title, systemImage: "puzzlepiece.extension")
                }
            }
        }

        Divider()
        Button { focus(entry); app.run(CommandID.reveal) } label: { Label("Reveal in Finder", systemImage: "magnifyingglass") }
        Button { focus(entry); app.run(CommandID.getInfo) } label: { Label("Get Info", systemImage: "info.circle") }
        Button { focus(entry); app.run(CommandID.copyPath) } label: { Label("Copy Path", systemImage: "link") }
    }

    /// Share / AirDrop the row (or the whole selection when the row is in it).
    @ViewBuilder
    private func shareMenu(_ entry: FSEntry) -> some View {
        let urls = tab.selection.contains(entry.url) ? Array(tab.selection) : [entry.url]
        let services = app.sharingServices(for: urls)
        if !services.isEmpty {
            Menu {
                ForEach(services, id: \.title) { svc in
                    Button { app.share(urls, with: svc) } label: {
                        Label { Text(svc.title) } icon: { Image(nsImage: svc.image) }
                    }
                }
            } label: { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }

    /// Menu for empty pane background — no selection target.
    @ViewBuilder
    private func backgroundMenu() -> some View {
        Button("New Folder…") { app.run(CommandID.newFolder) }
        if app.clipboard?.urls.isEmpty == false {
            Button("Paste") { app.run(CommandID.paste) }
        }
        Divider()
        Menu("Sort By") {
            ForEach(SortKey.allCases, id: \.self) { key in
                let active = tab.sortOrder.key == key
                Button {
                    app.activePaneIsLeft = tabBelongsToLeft()
                    app.sortBy(key)
                } label: {
                    Label(key.rawValue.capitalized,
                          systemImage: active ? (tab.sortOrder.ascending ? "chevron.up" : "chevron.down") : "")
                }
            }
        }
        Button {
            tab.showHidden.toggle()
        } label: {
            Label("Show Hidden Files", systemImage: tab.showHidden ? "checkmark" : "")
        }
        Divider()
        Button("Search…") { app.activePaneIsLeft = tabBelongsToLeft(); app.run(CommandID.search) }
        Button("Add Current Folder to Favorites") { app.addBookmark(tab.directory) }
        Button("Refresh") { tab.load() }
        let pluginCmds = app.pluginCommands()
        if !pluginCmds.isEmpty {
            Divider()
            ForEach(pluginCmds, id: \.id) { cmd in
                Button(cmd.title) { app.run(cmd.id) }
            }
        }
    }
}

/// Conditional folder-row drop target. Folder rows accept dropped URLs (copy, or
/// move on ⌘) and draw an accent ring while targeted; file rows opt out so a drop
/// falls through to the pane background. A modifier keeps the per-row call site in
/// `Views` to a single line and confines the `if enabled` branch.
private struct FolderDrop: ViewModifier {
    let enabled: Bool
    let onDrop: ([URL]) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        if enabled {
            content
                .dropDestination(for: URL.self) { urls, _ in onDrop(urls); return true }
                isTargeted: { targeted = $0 }
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: Theme.cornerRadius)
                            .strokeBorder(Theme.Palette.cursorStroke, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - Status bar

struct StatusBarView: View {
    let tab: TabModel
    private static let bcf: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .file; return f }()

    var body: some View {
        let rows = tab.displayed
        let selCount = tab.selection.count
        let selBytes = selCount == 0 ? 0
            : rows.reduce(Int64(0)) { tab.selection.contains($1.url) ? $0 + ($1.size ?? 0) : $0 }
        // Only show a byte total when the selection actually has measurable
        // bytes — folders report no size, so a folder selection showed "Zero KB".
        let sizePart = selBytes > 0 ? " (\(Self.bcf.string(fromByteCount: selBytes)))" : ""
        return HStack {
            Text("\(rows.count) items")
            if selCount > 0 {
                Text("· \(selCount) selected\(sizePart)")
            }
            Spacer()
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.bar)
    }
}

// MARK: - Operation queue (always visible while work runs)

struct QueueView: View {
    let app: AppState

    var body: some View {
        if !app.operations.isEmpty {
            VStack(spacing: 2) {
                ForEach(app.operations) { op in
                    HStack(spacing: 8) {
                        Text(op.task.kind.verb).font(.caption.bold()).frame(width: 70, alignment: .leading)
                        ProgressView(value: op.progress.fraction)
                        Text(statusText(op)).font(.caption2).foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
                        if !op.isTerminal {
                            Button { app.cancel(op.id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Cancel \(op.task.kind.verb)")
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .padding(.vertical, 4)
            .background(.regularMaterial)
        }
    }

    private func statusText(_ op: OperationItem) -> String {
        switch op.progress.state {
        case .running:
            let done = ByteCountFormatter.string(fromByteCount: op.progress.completedBytes, countStyle: .file)
            return "\(done) · \(Int(op.progress.fraction * 100))%"
        case .done: return "Done"
        case .cancelled: return "Cancelled"
        case .failed(let m): return m
        }
    }
}
