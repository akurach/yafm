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

    private func activateSelf() { app.activePaneIsLeft = (pane.id == app.left.id) }

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(pane: pane, activate: activateSelf)
            // Active pane: 2 pt accent bar between tabs and path bar.
            // Placed here (not above the tab strip) so it doesn't cut across tabs.
            Rectangle()
                .fill(isActive ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5))
                .frame(height: 2)
            PathBarView(tab: pane.active, app: app, activate: activateSelf)
            // Inline find bar (⌘F) on the active pane only — replaces the modal.
            if isActive && app.searchActive {
                Divider()
                SearchBar(app: app)
            }
            Divider()
            FileTableView(tab: pane.active, app: app)
        }
        .background(isActive ? Theme.Palette.activePaneTint : Color.clear)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { activateSelf() })
    }
}

// MARK: - Tab bar

struct TabBarView: View {
    @Bindable var pane: PaneModel
    var activate: () -> Void = {}

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
                    .padding(.horizontal, Theme.Space.row).padding(.vertical, Theme.Space.tight)
                    .background(idx == pane.activeIndex ? Theme.Palette.tabActive : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    .onTapGesture { activate(); pane.select(tab.id) }
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
    var app: AppState? = nil
    var activate: () -> Void = {}
    @State private var editing = false
    @State private var typed = ""
    @State private var showColumns = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if editing {
                TextField("Path", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(IBMPlex.mono(12))
                    .focused($focused)
                    .onSubmit {
                        let expanded = (typed as NSString).expandingTildeInPath
                        if !expanded.isEmpty, !expanded.contains("\0"), expanded.hasPrefix("/") {
                            tab.open(URL(fileURLWithPath: expanded))
                        }
                        editing = false
                    }
                    .onExitCommand { editing = false }
            } else {
                breadcrumbs
                Spacer()
                if let app, tab.viewMode == .list {
                    Button { showColumns.toggle() } label: {
                        Image(systemName: "slider.horizontal.3")
                    }.buttonStyle(.plain)
                    .accessibilityLabel("Columns")
                    .popover(isPresented: $showColumns, arrowEdge: .bottom) {
                        ColumnOptionsPopover(settings: app.settings)
                    }
                }
                Button {
                    tab.viewMode = tab.viewMode == .list ? .icons : .list
                } label: {
                    Image(systemName: tab.viewMode == .list ? "square.grid.2x2" : "list.bullet")
                }.buttonStyle(.plain)
                .accessibilityLabel("Toggle view mode")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(.bar)
        .onTapGesture {
            activate()
            guard !editing else { return }
            typed = tab.directory.path
            editing = true
        }
        .onChange(of: editing) { _, on in
            if on { focused = true }
        }
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
                    .font(IBMPlex.mono(11))
                    if i < comps.count - 1 { Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(.tertiary) }
                }
            }
        }
    }
}

/// Column show/hide — a discoverable popover off the path bar's options button
/// (also available by right-clicking the column header). Name is always shown.
struct ColumnOptionsPopover: View {
    @Bindable var settings: AppSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COLUMNS").font(IBMPlex.sans(10, weight: .semibold)).foregroundStyle(.secondary)
            Toggle("Size", isOn: $settings.showSizeColumn)
            Toggle("Modified", isOn: $settings.showModifiedColumn)
            Toggle("Kind", isOn: $settings.showKindColumn)
            Toggle("Git status", isOn: $settings.showGitColumn)
        }
        .toggleStyle(.checkbox)
        .padding(12)
        .frame(width: 180)
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
                Group {
                    if tab.viewMode == .list { rows } else { iconGrid }
                }
                .overlay(alignment: .top) {
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

    // Column widths persisted via @AppStorage so they survive relaunches.
    // Shared between both panes (Total Commander convention — one set of widths).
    @AppStorage("yafm.col.nameW") private var nameW: Double = 200
    @AppStorage("yafm.col.sizeW") private var sizeW: Double = 78
    @AppStorage("yafm.col.modW")  private var modW:  Double = 124
    @AppStorage("yafm.col.kindW") private var kindW: Double = 92
    @AppStorage("yafm.col.gitW")  private var gitW:  Double = 34
    /// Captured from the column-header geometry — drives `effectiveNameW`. A safe
    /// 600 default so the clamp is active from the first frame (before geometry).
    @State private var paneWidth: Double = 600
    @State private var pluginWidths: [String: Double] = [:]
    // Plugin columns filtered to those relevant for the current folder's content.
    @State private var visiblePluginCols: [PluginColumn] = []

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
                            // Deterministic leading/trailing inset = the header's,
                            // so columns line up (design audit). Vertical comes
                            // from the row's own density padding.
                            .listRowInsets(EdgeInsets(top: 0, leading: Theme.Space.rowLeading,
                                                      bottom: 0, trailing: Theme.Space.rowLeading))
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
                            .simultaneousGesture(TapGesture(count: 2).onEnded { openEntry(entry) })
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
            // NB: the tag-editor sheet is presented ONCE from RootView, not here —
            // FileTableView exists twice (one per pane), so two .sheet modifiers bound
            // to the same app.tagSheet fought to present it and the modal flickered.
            .contextMenu { backgroundMenu() }   // empty area below the rows
            .background(PaneActivationOverlay { app.activePaneIsLeft = tabBelongsToLeft() })
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
                // Minimal scroll (nil anchor): only moves if the row is off-screen.
                // Centering on every cursor change yanked the list on a plain click.
                proxy.scrollTo(new)
                // Follow the cursor with QuickLook when its panel is open.
                if tab.id == app.activeTab.id {
                    QuickLook.updateIfVisible(urls: tab.actionable.map(\.url))
                }
            }
            .onChange(of: tab.displayed) { _, entries in refreshVisiblePluginCols(entries) }
            .onChange(of: tab.directory) { Self.iCloudCache.removeAll() }
            .onChange(of: pluginWidths) {
                if let data = try? JSONEncoder().encode(pluginWidths) {
                    UserDefaults.standard.set(data, forKey: "yafm.col.pluginWidths")
                }
            }
            .onAppear {
                refreshVisiblePluginCols(tab.displayed)
                if let data = UserDefaults.standard.data(forKey: "yafm.col.pluginWidths"),
                   let saved = try? JSONDecoder().decode([String: Double].self, from: data) {
                    pluginWidths = saved
                }
            }
        }
    }

    // Show only plugin columns that are relevant for the current listing:
    // a column with `relevantExtensions` set is hidden when no file in the
    // folder has a matching extension (e.g. Camera/Focal/f in non-image folders).
    private func refreshVisiblePluginCols(_ entries: [FSEntry]) {
        visiblePluginCols = app.registry.pluginColumns.filter { col in
            guard let exts = col.relevantExtensions else { return true }
            return entries.contains { exts.contains($0.url.pathExtension.lowercased()) }
        }
    }

    // Sum of all fixed-width columns + handles + padding (excludes nameW).
    // Drives the Name snap/clamp in the GeometryReader below (nameW = pane − this).
    private var fixedColumnsWidth: Double {
        let iconW = Double(app.settings.density.iconSize)
        var w = iconW + Double(Theme.Space.row) + 8  // icon + gap + H1 (always)
        if showSize     { w += sizeW + 8 }
        if showModified { w += modW + 8 }
        if showKind     { w += kindW }
        let hasPlugins = !visiblePluginCols.isEmpty
        if showKind && (showGit || hasPlugins) { w += 8 }   // kindBind handle
        if showGit { w += gitW; if hasPlugins { w += 8 } }
        for col in visiblePluginCols { w += (pluginWidths[col.id] ?? 104) + 8 }
        w += 2 * Double(Theme.Space.rowLeading)
        return w
    }

    /// Displayed Name width = the stored preference, clamped to the space left in
    /// the pane (min 80). This is load-bearing: without it the row can exceed the
    /// pane width (a too-wide Name, many plugin columns, or a corrupt stored value),
    /// and that horizontal overflow sends AppKit's layout engine into an infinite
    /// `_layoutSubtree` recursion that freezes the app. Clamping the *display* (not
    /// mutating `nameW`) keeps the row within the pane with no state write that loops.
    private var effectiveNameW: Double { max(80, min(nameW, paneWidth - fixedColumnsWidth)) }

    // Column visibility (Name is always shown). Git also needs the folder to be a repo.
    private var showSize: Bool { app.settings.showSizeColumn }
    private var showModified: Bool { app.settings.showModifiedColumn }
    private var showKind: Bool { app.settings.showKindColumn }
    private var showGit: Bool { app.settings.showGitColumn && !tab.gitStatus.isEmpty }

    // Column resize: all handles compensate via Kind (rightmost). Dragging H1/H2/H3
    // right makes the left column grow; Kind absorbs by shrinking. The columns between
    // the dragged handle and Kind shift right as a unit without changing their widths.
    // Result: "right block slides" — matches the behavior users expect from Finder.
    //   H1 Name grows  → kindW shrinks, Size+Mod+Kind block shifts right
    //   H2 Size grows  → kindW shrinks, Mod+Kind block shifts right
    //   H3 Mod grows   → kindW shrinks, Kind shifts (same as pairwise)
    //   H4 Kind grows  → nameW shrinks (only visible with git/plugin columns)
    private var nameBind: Binding<Double> {
        Binding(get: { nameW }, set: { v in
            let d = v - nameW
            let give = d > 0 ? min(d, kindW - 40) : max(d, -(nameW - 80))
            nameW += give; kindW -= give
        })
    }
    private var sizeBind: Binding<Double> {
        Binding(get: { sizeW }, set: { v in
            let d = v - sizeW
            let give = d > 0 ? min(d, kindW - 40) : max(d, -(sizeW - 40))
            sizeW += give; kindW -= give
        })
    }
    private var modBind: Binding<Double> {
        Binding(get: { modW }, set: { v in
            let d = v - modW
            let give = d > 0 ? min(d, kindW - 40) : max(d, -(modW - 40))
            modW += give; kindW -= give
        })
    }
    private var kindBind: Binding<Double> {
        Binding(get: { kindW }, set: { v in
            let d = v - kindW
            let give = d > 0 ? min(d, nameW - 80) : max(d, -(kindW - 40))
            kindW += give; nameW -= give
        })
    }
    private func pluginWidth(_ col: PluginColumn) -> CGFloat {
        CGFloat(pluginWidths[col.id] ?? 104)
    }
    private func pluginWidthBind(_ col: PluginColumn) -> Binding<Double> {
        Binding(
            get: { pluginWidths[col.id] ?? 104 },
            set: { pluginWidths[col.id] = max(40, $0) }
        )
    }

    private var columnHeader: some View {
        // spacing:0 — columns separated by 8-pt ColResizeHandle. Kind absorbs all
        // resizes (all handles compensate via kindW) so the right block slides right
        // as a unit when any column grows. H4 (after Kind) compensates via nameW.
        HStack(spacing: 0) {
            Color.clear.frame(width: app.settings.density.iconSize)
            Color.clear.frame(width: Theme.Space.row)
            headerButton("Name", .name)
                .frame(width: max(0, CGFloat(effectiveNameW)), alignment: .leading)
            ColResizeHandle(width: nameBind)
            headerTrailingColumns
        }
        .font(Theme.Font.header)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Space.rowLeading).padding(.vertical, Theme.Space.tight)
        .background(.bar)
        // Read-only width probe: only writes @State paneWidth (never @AppStorage),
        // so it can't feed back into layout. Drives effectiveNameW's clamp.
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { paneWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in paneWidth = w }
            }
        }
        // Column show/hide lives here — right-click the header — not in Settings.
        .contextMenu { columnVisibilityMenu }
    }

    // Extracted from columnHeader to keep that HStack within the Swift type-checker's
    // reach (the conditional column blocks pushed it to a timeout otherwise).
    @ViewBuilder private var headerTrailingColumns: some View {
        if showSize {
            headerButton("Size", .size).frame(width: CGFloat(sizeW), alignment: .trailing)
            ColResizeHandle(width: sizeBind)
        }
        if showModified {
            headerButton("Modified", .modified).frame(width: CGFloat(modW), alignment: .trailing)
            ColResizeHandle(width: modBind)
        }
        if showKind {
            headerButton("Kind", .kind).frame(width: CGFloat(kindW), alignment: .leading)
            if showGit || !visiblePluginCols.isEmpty { ColResizeHandle(width: kindBind) }
        }
        if showGit {
            Text("Git").frame(width: CGFloat(gitW), alignment: .center)
            if !visiblePluginCols.isEmpty {
                ColResizeHandle(width: Binding(get: { gitW }, set: { gitW = max(28, $0) }))
            }
        }
        ForEach(visiblePluginCols) { col in
            Text(col.title).lineLimit(1).frame(width: pluginWidth(col), alignment: .leading)
            ColResizeHandle(width: pluginWidthBind(col))
        }
    }

    @ViewBuilder private var columnVisibilityMenu: some View {
        Section("Columns") {
            Toggle("Size",     isOn: Binding(get: { app.settings.showSizeColumn },     set: { app.settings.showSizeColumn = $0 }))
            Toggle("Modified", isOn: Binding(get: { app.settings.showModifiedColumn }, set: { app.settings.showModifiedColumn = $0 }))
            Toggle("Kind",     isOn: Binding(get: { app.settings.showKindColumn },     set: { app.settings.showKindColumn = $0 }))
            Toggle("Git status", isOn: Binding(get: { app.settings.showGitColumn },    set: { app.settings.showGitColumn = $0 }))
        }
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

    private var isPaneActive: Bool { tabBelongsToLeft() == app.activePaneIsLeft }

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

    /// A package is a directory the system treats as a single file (`.app`, `.bundle`,
    /// `.rtfd`, photo libraries…). Double-click should OPEN it (launch the app), not
    /// navigate into it; → (right arrow) still enters it as a folder to browse inside.
    private func isPackage(_ entry: FSEntry) -> Bool {
        entry.isDirectory && NSWorkspace.shared.isFilePackage(atPath: entry.url.path)
    }

    /// Double-click / open: enter real folders, browse a `.zip`, otherwise open the
    /// file — and that includes packages (`.app` launches via the system).
    private func openEntry(_ entry: FSEntry) {
        if entry.isDirectory && !isPackage(entry) { tab.open(entry.url) }
        else if !entry.isDirectory && entry.url.pathExtension.lowercased() == "zip" { app.browseArchive(entry.url) }
        else { app.openFile(entry.url) }
    }

    private func row(_ entry: FSEntry) -> some View {
        let density = app.settings.density
        // Tie rows to the async-plugin version so a resolved value re-renders.
        let _ = app.pluginValuesVersion
        return HStack(spacing: Theme.Space.row) {
            // Real macOS file-type icon (cached). A color-coding rule, if any,
            // now tints the name instead of the icon so the true icon shows.
            FileIconView(entry: entry, size: density.iconSize, tile: app.settings.tileTint(for: entry))
                .frame(width: density.iconSize)
            // Name cell: filename + optional iCloud badge + color tags — packed into
            // a single fixed-width frame so the Size column never shifts between rows.
            HStack(spacing: 2) {
                Text(entry.name)
                    .font(density.rowFont)
                    .foregroundStyle(nameColor(entry))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let cloudIcon = iCloudIcon(entry) {
                    Image(systemName: cloudIcon)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                ForEach(entry.tags, id: \.name) { tag in
                    Circle().fill(Color.named(tag.colorName) ?? .secondary)
                        .frame(width: Theme.Col.tagDot, height: Theme.Col.tagDot)
                }
            }
            .frame(width: max(0, CGFloat(effectiveNameW)), alignment: .leading)
            .clipped()
            if showSize {
                Text(entry.isDirectory ? "--" : (entry.size.map(byteString) ?? "--"))
                    .font(Theme.Font.mono).foregroundStyle(.secondary)
                    .frame(width: CGFloat(sizeW), alignment: .trailing)
            }
            if showModified {
                Text(entry.modified.map { modifiedText($0) } ?? "--")
                    .font(Theme.Font.mono).foregroundStyle(.secondary)
                    .frame(width: CGFloat(modW), alignment: .trailing)
            }
            if showKind {
                Text(kindText(entry))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: CGFloat(kindW), alignment: .leading)
            }
            if showGit {
                Text(tab.gitStatus[entry.url] ?? "")
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(gitColor(tab.gitStatus[entry.url]))
                    .frame(width: CGFloat(gitW), alignment: .center)
            }
            ForEach(visiblePluginCols) { col in
                Text(pluginText(col, entry))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: pluginWidth(col), alignment: .leading)
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
            app.scheduleValuesBump()   // coalesced — avoids O(n²) re-render churn on load
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
    @MainActor private static var kindCache: [String: String] = [:]
    private func kindText(_ entry: FSEntry) -> String {
        let ext = entry.url.pathExtension
        if entry.isDirectory && ext.isEmpty { return "Folder" }
        if let hit = Self.kindCache[ext] { return hit }
        let text: String
        // A package (dir with ext, e.g. .app) resolves to its real kind ("Application").
        if let t = UTType(filenameExtension: ext), let d = t.localizedDescription { text = d }
        else if entry.isDirectory { text = "Folder" }
        else { text = ext.isEmpty ? "Document" : ext.uppercased() }
        Self.kindCache[ext] = text
        return text
    }

    static func dateText(_ d: Date) -> String { Self.df.string(from: d) }
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    // Width-adaptive date for the Modified column — more detail when wider.
    // Today's files show only the time (same as Finder).
    private func modifiedText(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return Self.dfTime.string(from: d) }
        if modW < 72  { return Self.dfShort.string(from: d) }
        if modW < 128 { return Self.dfMed.string(from: d) }
        return Self.dfLong.string(from: d)
    }
    private static let dfTime:  DateFormatter = { let f = DateFormatter(); f.dateStyle = .none;   f.timeStyle = .short;  return f }()
    private static let dfShort: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short;  f.timeStyle = .none;   return f }()
    private static let dfMed:   DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none;   return f }()
    private static let dfLong:  DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short;  return f }()
    // PERF: one shared formatter — the class method `ByteCountFormatter.string`
    // allocates a formatter per call (perf P2-E).
    private static let bcf: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()

    /// SF Symbol name for iCloud sync state, or nil when the file is fully local.
    /// Results cached per-URL (main actor only); cleared when directory changes.
    @MainActor private static var iCloudCache: [URL: String?] = [:]

    private func iCloudIcon(_ entry: FSEntry) -> String? {
        if let cached = Self.iCloudCache[entry.url] { return cached }
        guard !entry.isDirectory else { Self.iCloudCache[entry.url] = nil; return nil }
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey]
        let result: String?
        if let vals = try? entry.url.resourceValues(forKeys: keys),
           let status = vals.ubiquitousItemDownloadingStatus,
           status == .notDownloaded {
            result = "icloud.and.arrow.down"
        } else {
            result = nil
        }
        Self.iCloudCache[entry.url] = result
        return result
    }

    /// Color-coding rule tints the name (the icon now shows the real file type).
    private func nameColor(_ entry: FSEntry) -> Color {
        // Tag/regex color rules win (explicit user intent). Then, only if the user
        // opted in, tint by file type — using the SAME category color as the tile,
        // so the name and its chip can never disagree.
        if let c = Color.named(app.colorCoder.colorName(for: entry)) { return c }
        if app.settings.tintNamesByType, !entry.isDirectory,
           let (cat, _) = app.settings.typeMapping(forExtension: entry.url.pathExtension) {
            return app.settings.color(for: cat)
        }
        return entry.isHidden ? .secondary : .primary
    }

    /// Selection is a full-width wash; the keyboard cursor is a thin accent bar
    /// down the leading edge — distinct from selection without boxing the row in
    /// a heavy ring (the v0.4 ring read as a clunky border on the focused row).
    @ViewBuilder
    private func rowBackground(_ entry: FSEntry) -> some View {
        let selected = tab.selection.contains(entry.url)
        let cursored = tab.cursor == entry.url
        let active = isPaneActive
        HStack(spacing: 0) {
            Rectangle()
                .fill(cursored
                      ? (active ? Theme.Palette.cursorStroke
                                : Theme.Palette.cursorStroke.opacity(0.35))
                      : Color.clear)
                .frame(width: Theme.cursorBarWidth)
            Rectangle()
                .fill(selected ? (active ? Theme.Palette.selectionFill
                                         : Theme.Palette.selectionFill.opacity(0.4))
                      : cursored ? (active ? Theme.Palette.cursorFill
                                           : Theme.Palette.cursorFill.opacity(0.4))
                      : Color.clear)
        }
    }

    private func byteString(_ n: Int64) -> String {
        Self.bcf.string(fromByteCount: n)
    }

    // MARK: Icon grid view

    private var iconGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))], spacing: 12) {
                ForEach(tab.displayed) { entry in
                    VStack(spacing: 4) {
                        FileIconView(entry: entry, size: 48, tile: app.settings.tileTint(for: entry)).frame(width: 48, height: 48)
                        Text(entry.name)
                            .font(IBMPlex.mono(11))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(nameColor(entry))
                    }
                    .frame(width: 72)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(tab.selection.contains(entry.url)
                                  ? Theme.Palette.selectionFill
                                  : tab.cursor == entry.url ? Theme.Palette.cursorFill : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        app.activePaneIsLeft = tabBelongsToLeft()
                        let mods = NSEvent.modifierFlags
                        if mods.contains(.command) {
                            if tab.selection.contains(entry.url) { tab.selection.remove(entry.url) }
                            else { tab.selection.insert(entry.url) }
                            tab.cursor = entry.url
                        } else {
                            tab.cursor = entry.url
                            tab.selection = [entry.url]
                        }
                    }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { openEntry(entry) })
                    .contextMenu { rowMenu(entry) }
                }
            }
            .padding(8)
        }
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

    /// Menu for a file/selection — kept FLAT (no nested `Menu`/`ForEach`).
    /// SwiftUI builds a row's `.contextMenu` content eagerly for *every* row, so
    /// nested submenus that enumerate apps (Open With) and share services (Share)
    /// were built 286× and froze big folders. Open With / Share are now single
    /// buttons that open the system picker on demand. (perf — user-confirmed.)
    /// Quick tag assignment from the row's context menu — lists the user's ACTUAL
    /// tags (from the index) to toggle, offers standard colors not yet used, and a
    /// "New Tag…" prompt. Each item shows a real colored dot.
    @ViewBuilder private func tagMenu(_ entry: FSEntry) -> some View {
        // Normalize spelling so a custom "Grey" tag isn't duplicated by standard "Gray".
        let knownNorm = Set(app.knownTags.map { Self.normTag($0.name) })
        ForEach(app.knownTags, id: \.name) { tag in
            let on = entry.tags.contains { $0.name == tag.name }
            Button {
                focus(entry)
                app.toggleColorTag(name: tag.name, colorIndex: tag.colorIndex ?? 0, on: entry)
            } label: {
                Label { Text(tag.name) } icon: { Image(nsImage: Self.tagDot(tag.colorName, filled: on)) }
            }
        }
        let unused = Array(Tag.colorNames.dropFirst().enumerated())
            .filter { !knownNorm.contains(Self.normTag($0.element)) }
        if !app.knownTags.isEmpty && !unused.isEmpty { Divider() }
        ForEach(unused, id: \.element) { offset, name in
            Button { focus(entry); app.toggleColorTag(name: name, colorIndex: offset + 1, on: entry) } label: {
                Label { Text(name) } icon: { Image(nsImage: Self.tagDot(name, filled: false)) }
            }
        }
        Divider()
        Button { focus(entry); app.promptNewTag(on: entry) } label: { Label("New Tag…", systemImage: "plus") }
    }

    private static func normTag(_ s: String) -> String {
        let l = s.lowercased(); return l == "grey" ? "gray" : l
    }

    private static func tagNSColor(_ name: String?) -> NSColor? {
        switch name?.lowercased() {
        case "gray", "grey": return .systemGray
        case "green":  return .systemGreen
        case "purple": return .systemPurple
        case "blue":   return .systemBlue
        case "yellow": return .systemYellow
        case "red":    return .systemRed
        case "orange": return .systemOrange
        default:       return nil
        }
    }

    /// A small colored dot for a tag menu item. Non-template so the menu draws it in
    /// color (template images render monochrome). Filled = applied, ring = not.
    private static func tagDot(_ colorName: String?, filled: Bool) -> NSImage {
        let color = tagNSColor(colorName) ?? .tertiaryLabelColor
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            if filled { color.setFill(); path.fill() }
            color.setStroke(); path.lineWidth = 1.5; path.stroke()
            return true
        }
        img.isTemplate = false
        return img
    }

    @ViewBuilder
    private func rowMenu(_ entry: FSEntry) -> some View {
        Button { focus(entry); app.openCursor() } label: { Label("Open", systemImage: "arrow.up.forward.app") }
        if isPackage(entry) {
            Button { focus(entry); tab.open(entry.url) } label: { Label("Show Package Contents", systemImage: "folder") }
        }
        Button { focus(entry); app.openWithOther(entry.url) } label: { Label("Open With…", systemImage: "square.and.arrow.up.on.square") }
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
        // Tags write an xattr ONTO the file; for an app bundle macOS App Management
        // blocks that, so don't offer tagging for packages.
        if !isPackage(entry) {
            Menu { tagMenu(entry) } label: { Label("Tags", systemImage: "tag") }
        }
        Button { focus(entry); app.sharePicker(for: tab.actionable.map(\.url)) } label: { Label("Share…", systemImage: "square.and.arrow.up") }

        if entry.isDirectory {
            Button { app.addBookmark(entry.url) } label: { Label("Add to Favorites", systemImage: "star") }
        }

        // JS plugin context-menu items (v0.8) — flat buttons; the list is empty
        // unless a menu-contributing plugin is enabled, so this stays cheap.
        ForEach(app.pluginMenuItems(), id: \.id) { item in
            Button { focus(entry); app.runPluginMenuItem(item.id, on: entry) } label: {
                Label(item.title, systemImage: "puzzlepiece.extension")
            }
        }

        Divider()
        Button { focus(entry); app.run(CommandID.reveal) } label: { Label("Reveal in Finder", systemImage: "magnifyingglass") }
        Button { focus(entry); app.run(CommandID.getInfo) } label: { Label("Get Info", systemImage: "info.circle") }
        Button { focus(entry); app.run(CommandID.copyPath) } label: { Label("Copy Path", systemImage: "link") }
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
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.clear)
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

// MARK: - Column resize handle

// @Binding + incremental-delta (per-frame, not cumulative from drag start):
//   - @Binding keeps gesture @State stable across parent re-renders
//   - incremental delta means no "reversal jump" after hitting a clamp —
//     releasing and re-gripping the column starts fresh at the clamped value
//   - coordinateSpace: .global → cursor position is window-space, unaffected
//     by the column shifting under the handle as it resizes
// Clamping lives in the Binding.set at the callsite, not here.
private struct ColResizeHandle: View {
    @Binding var width: Double
    @State private var hovering = false
    @State private var dragging = false
    @State private var lastX: CGFloat = 0

    var body: some View {
        ZStack {
            Color.clear.frame(width: 8)
            Rectangle()
                .fill(Color.primary.opacity(hovering || dragging ? 0.35 : 0.12))
                .frame(width: 1)
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovering { NSCursor.pop() } }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { v in
                    if !dragging { dragging = true; lastX = v.location.x }
                    let delta = v.location.x - lastX
                    lastX = v.location.x
                    width += delta   // binding setter does clamping + compensation
                }
                .onEnded { _ in dragging = false }
        )
    }
}

// MARK: - NSEvent-based pane activation for AppKit-hosted areas (List background)

/// Invisible background NSView that fires `activate()` on any left-click within
/// its bounds. Needed because NSScrollView+NSTableView eat SwiftUI gestures.
struct PaneActivationOverlay: NSViewRepresentable {
    let activate: () -> Void

    func makeNSView(context: Context) -> _ActivationView { _ActivationView(activate: activate) }
    func updateNSView(_ v: _ActivationView, context: Context) { v.activate = activate }

    final class _ActivationView: NSView {
        var activate: () -> Void
        nonisolated(unsafe) private var monitor: Any?

        init(activate: @escaping () -> Void) {
            self.activate = activate
            super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handle(event)
                return event  // always forward — never consume
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

        private func handle(_ event: NSEvent) {
            guard let w = event.window, w == window else { return }
            let loc = convert(event.locationInWindow, from: nil)
            if bounds.contains(loc) { activate() }
        }
    }
}
