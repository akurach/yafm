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
            Divider()
            FileTableView(tab: pane.active, app: app)
        }
        .background(isActive ? Color.accentColor.opacity(0.06) : Color.clear)
        .overlay(alignment: .top) {
            if isActive {
                Rectangle().fill(Color.accentColor).frame(height: 2)
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
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(idx == pane.activeIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .onTapGesture { pane.select(tab.id) }
                }
                Button { pane.newTab() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).padding(.horizontal, 4)
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
    let app: AppState

    var body: some View {
        Group {
            switch tab.state {
            case .idle:
                Color.clear
            case .loading(let partial):
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading… (\(partial.count))").foregroundStyle(.secondary).font(.caption)
                    }.padding(6)
                    rows
                }
            case .loaded:
                rows
            case .failed(let message):
                ContentUnavailableView("Can't open folder", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Fixed column widths; Name flexes. Header aligns to these.
    private let sizeW: CGFloat = 78
    private let modW: CGFloat = 124
    private let kindW: CGFloat = 92

    private var rows: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider()
            rowList
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 16)   // aligns with the row icon
            headerButton("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
            headerButton("Size", .size).frame(width: sizeW, alignment: .trailing)
            headerButton("Modified", .modified).frame(width: modW, alignment: .trailing)
            headerButton("Kind", .kind).frame(width: kindW, alignment: .leading)
        }
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

    private var rowList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(tab.displayed) { entry in
                    row(entry)
                        .id(entry.url)
                        .listRowBackground(rowBackground(entry))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if entry.isDirectory { tab.open(entry.url) } else { app.openFile(entry.url) }
                        }
                        .onTapGesture {
                            tab.cursor = entry.url
                            tab.selection = [entry.url]
                            app.activePaneIsLeft = (tabBelongsToLeft())
                        }
                        .contextMenu { rowMenu(entry) }
                }
            }
            .contextMenu { backgroundMenu() }   // empty area below the rows
            .listStyle(.inset)
            .onChange(of: tab.cursor) { _, new in
                if let new { withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) } }
            }
        }
    }

    private func tabBelongsToLeft() -> Bool {
        app.left.tabs.contains { $0.id == tab.id }
    }

    private func row(_ entry: FSEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(iconColor(entry))
                .frame(width: 16)
            Text(entry.name)
                .foregroundStyle(entry.isHidden ? .secondary : .primary)
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
        }
        .padding(.vertical, 1)
    }

    private func kindText(_ entry: FSEntry) -> String {
        if entry.isDirectory { return "Folder" }
        let ext = entry.url.pathExtension
        if let t = UTType(filenameExtension: ext), let d = t.localizedDescription { return d }
        return ext.isEmpty ? "Document" : ext.uppercased()
    }

    static func dateText(_ d: Date) -> String { Self.df.string(from: d) }
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private func iconColor(_ entry: FSEntry) -> Color {
        if let c = Color.named(app.colorCoder.colorName(for: entry)) { return c }
        return entry.isDirectory ? .accentColor : .secondary
    }

    private func rowBackground(_ entry: FSEntry) -> some View {
        let selected = tab.selection.contains(entry.url)
        let cursored = tab.cursor == entry.url
        return Rectangle().fill(
            selected ? Color.accentColor.opacity(0.25) :
            cursored ? Color.accentColor.opacity(0.10) : Color.clear
        )
    }

    private func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    // MARK: Context menus (§1)

    /// Menu for a file/selection. Right-clicking outside the selection focuses
    /// the row first so the existing `actionable`-based commands target it.
    @ViewBuilder
    private func rowMenu(_ entry: FSEntry) -> some View {
        let _ = app.focusContextTarget(entry, in: tab)

        Button("Open") { app.openCursor() }
        Menu("Open With") {
            ForEach(app.applications(for: entry.url), id: \.self) { appURL in
                Button(appURL.deletingPathExtension().lastPathComponent) {
                    app.openFile(entry.url, withApplication: appURL)
                }
            }
            Divider()
            Button("Other…") { app.openWithOther(entry.url) }
        }
        Button("Quick Look") { QuickLook.toggle(urls: tab.actionable.map(\.url)) }

        Divider()
        Button("Copy → other pane") { app.run(CommandID.copy) }
        Button("Move → other pane") { app.run(CommandID.move) }
        Button("Copy") { app.run(CommandID.clipCopy) }
        Button("Cut") { app.run(CommandID.clipCut) }

        Divider()
        Button("Rename…") { app.run(CommandID.rename) }
        Button("New Folder…") { app.run(CommandID.newFolder) }
        Button("Delete") { app.run(CommandID.delete) }

        Divider()
        Menu("Tags") {
            ForEach(1..<Tag.colorNames.count, id: \.self) { i in
                let name = Tag.colorNames[i]
                let on = entry.tags.contains { $0.name == name }
                Button { app.toggleColorTag(name: name, colorIndex: i, on: entry) } label: {
                    Label(name, systemImage: on ? "checkmark.circle.fill" : "circle")
                }
            }
            Divider()
            Button("New Tag…") { app.promptNewTag(on: entry) }
        }

        Divider()
        Button("Reveal in Finder") { app.run(CommandID.reveal) }
        Button("Get Info") { app.run(CommandID.getInfo) }
        Button("Copy Path") { app.run(CommandID.copyPath) }
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
        Button("Refresh") { tab.load() }
    }
}

// MARK: - Status bar

struct StatusBarView: View {
    let tab: TabModel

    var body: some View {
        let rows = tab.displayed
        let selCount = tab.selection.count
        let selBytes = rows.filter { tab.selection.contains($0.url) }.compactMap(\.size).reduce(0, +)
        return HStack {
            Text("\(rows.count) items")
            if selCount > 0 {
                Text("· \(selCount) selected (\(ByteCountFormatter.string(fromByteCount: selBytes, countStyle: .file)))")
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

// MARK: - Sidebar: Favorites · Locations · Devices · Network (v0.2.1 §2)

struct BookmarksSidebar: View {
    @Bindable var app: AppState

    private var devices: [Volume] { app.volumes.filter { !$0.isNetwork } }
    private var networkVolumes: [Volume] { app.volumes.filter { $0.isNetwork } }

    var body: some View {
        List {
            Section("Favorites") {
                ForEach(app.bookmarks) { bm in
                    Label(bm.name, systemImage: "folder")
                        .contentShape(Rectangle())
                        .onTapGesture { app.activeTab.open(bm.url) }
                }
            }

            Section("Locations") {
                Label("Computer", systemImage: "desktopcomputer")
                    .contentShape(Rectangle())
                    .onTapGesture { app.activeTab.open(URL(fileURLWithPath: "/")) }
                Label("Home", systemImage: "house")
                    .contentShape(Rectangle())
                    .onTapGesture { app.activeTab.open(FileManager.default.homeDirectoryForCurrentUser) }
            }

            if !devices.isEmpty {
                Section("Devices") {
                    ForEach(devices) { vol in VolumeRow(app: app, volume: vol) }
                }
            }

            if !networkVolumes.isEmpty {
                Section("Network") {
                    ForEach(networkVolumes) { vol in VolumeRow(app: app, volume: vol) }
                }
            }

            if !app.knownTags.isEmpty {
                Section("Tags") {
                    ForEach(app.knownTags, id: \.name) { tag in
                        TagCloudRow(app: app, tag: tag, count: app.tagCounts[tag.name] ?? 0)
                    }
                }
            }
        }
        .frame(minWidth: 170, maxWidth: 220)
    }
}

/// One tag in the sidebar cloud: color dot · name · file count. Click filters.
struct TagCloudRow: View {
    let app: AppState
    let tag: Tag
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.named(tag.colorName) ?? .secondary)
                .frame(width: 9, height: 9)
            Text(tag.name).lineLimit(1)
            Spacer()
            Text("\(count)").font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.openTag(tag) }
    }
}

/// One mounted volume: name, capacity bar, eject button for removables.
struct VolumeRow: View {
    let app: AppState
    let volume: Volume

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name).lineLimit(1)
                if let frac = volume.usedFraction {
                    ProgressView(value: frac)
                        .controlSize(.mini)
                    if let total = volume.totalCapacity, let avail = volume.availableCapacity {
                        Text("\(byte(total - avail)) of \(byte(total))")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if volume.canEject {
                Button { app.eject(volume) } label: { Image(systemName: "eject.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.activeTab.open(volume.url) }
    }

    private var icon: String {
        if volume.isNetwork { return "network" }
        if volume.canEject { return "externaldrive" }
        return "internaldrive"
    }

    private func byte(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// MARK: - Rename sheet (v0.1 single + v0.2 bulk regex preview)

struct RenameSheet: View {
    let app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var pattern = ""
    @State private var replacement = ""
    @State private var useRegex = false
    @State private var bulk = false

    var body: some View {
        let names = app.activeTab.actionable.map(\.name)
        VStack(alignment: .leading, spacing: 10) {
            Text(bulk ? "Bulk Rename (\(names.count))" : "Rename").font(.headline)
            Toggle("Bulk regex rename", isOn: $bulk).disabled(names.count < 2 && !bulk)

            if bulk {
                Toggle("Use regex", isOn: $useRegex)
                TextField("Find", text: $pattern).textFieldStyle(.roundedBorder)
                TextField("Replace (# = counter)", text: $replacement).textFieldStyle(.roundedBorder)
                let preview = RenameRule(pattern: pattern, replacement: replacement, useRegex: useRegex,
                                         sequenceStart: replacement.contains("#") ? 1 : nil).preview(names)
                ScrollView {
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, pair in
                        HStack {
                            Text(pair.from).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption2)
                            Text(pair.to).bold()
                        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(height: 120)
            } else {
                TextField("New name", text: $replacement).textFieldStyle(.roundedBorder)
                    .onAppear { replacement = names.first ?? "" }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename") { apply(names); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460)
    }

    private func apply(_ names: [String]) {
        if bulk {
            let rule = RenameRule(pattern: pattern, replacement: replacement, useRegex: useRegex,
                                  sequenceStart: replacement.contains("#") ? 1 : nil)
            let plan = rule.preview(names)
            for (entry, pair) in zip(app.activeTab.actionable, plan) where pair.from != pair.to {
                app.rename(entry: entry, to: pair.to)
            }
        } else {
            app.rename(to: replacement)
        }
    }
}

// MARK: - Function-key bar (TC-style, §3)

struct FunctionBarView: View {
    let app: AppState

    // (number, label, command). F7 New Folder reuses the §1 command.
    private let keys: [(Int, String, String)] = [
        (2, "Rename", CommandID.rename),
        (3, "View", CommandID.view),
        (4, "Edit", CommandID.edit),
        (5, "Copy", CommandID.copy),
        (6, "Move", CommandID.move),
        (7, "NewFolder", CommandID.newFolder),
        (8, "Delete", CommandID.delete),
    ]

    var body: some View {
        // Falls back to numbers-only when the window is too narrow for labels.
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
        .background(.bar)
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                FunctionKeyButton(number: k.0, label: k.1, compact: compact) { app.run(k.2) }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }
}

struct FunctionKeyButton: View {
    let number: Int
    let label: String
    let compact: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("F\(number)").font(.caption2.bold()).foregroundStyle(.secondary)
                if !compact { Text(label).font(.caption) }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hover ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Right inspector: Info / Preview modes (§4)

struct InspectorView: View {
    @Bindable var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $app.inspectorMode) {
                Text("Info").tag(AppState.InspectorMode.info)
                Text("Preview").tag(AppState.InspectorMode.preview)
            }
            .pickerStyle(.segmented).labelsHidden().padding(6)
            Divider()
            switch app.inspectorMode {
            case .info: InfoPanel(app: app, tab: app.activeTab)
            case .preview: PreviewPane(tab: app.activeTab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// Metadata inspector for the cursor/selection: icon, kind, size (folders sized
/// in the background), dates, POSIX permissions, path, and a tag editor.
struct InfoPanel: View {
    let app: AppState
    @Bindable var tab: TabModel
    @State private var folderSize: String?
    @State private var created: Date?
    @State private var perms = "—"
    @State private var newTag = ""

    var body: some View {
        let sel = tab.actionable
        ScrollView {
            if sel.isEmpty {
                ContentUnavailableView("No selection", systemImage: "info.circle")
                    .frame(maxWidth: .infinity)
            } else if sel.count > 1 {
                multi(sel)
            } else {
                single(sel[0])
            }
        }
    }

    @ViewBuilder
    private func single(_ entry: FSEntry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Spacer(); icon(entry.url); Spacer() }
            Text(entry.name).font(.headline).frame(maxWidth: .infinity).multilineTextAlignment(.center)
            Divider()
            field("Kind", kind(entry))
            field("Size", sizeValue(entry))
            field("Created", created.map(Self.dateStr) ?? "—")
            field("Modified", entry.modified.map(Self.dateStr) ?? "—")
            field("Permissions", perms)
            field("Where", entry.url.deletingLastPathComponent().path)
            Divider()
            Text("Tags").font(.caption.bold()).foregroundStyle(.secondary)
            tagEditor(entry)
        }
        .padding(12)
        .task(id: entry.url) { await loadMeta(entry) }
    }

    @ViewBuilder
    private func multi(_ sel: [FSEntry]) -> some View {
        let total = sel.compactMap(\.size).reduce(0, +)
        VStack(alignment: .leading, spacing: 9) {
            Text("\(sel.count) items").font(.headline)
            Divider()
            field("Items", "\(sel.count)")
            field("Total size", Self.byteStr(total))
        }
        .padding(12)
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 86, alignment: .trailing)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }

    private func icon(_ url: URL) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable().frame(width: 64, height: 64)
    }

    private func sizeValue(_ entry: FSEntry) -> String {
        if entry.isDirectory { return folderSize ?? "calculating…" }
        return entry.size.map(Self.byteStr) ?? "—"
    }

    private func kind(_ entry: FSEntry) -> String {
        if entry.isDirectory { return "Folder" }
        let ext = entry.url.pathExtension
        if let t = UTType(filenameExtension: ext), let d = t.localizedDescription { return d }
        return ext.isEmpty ? "Document" : ext.uppercased()
    }

    @ViewBuilder
    private func tagEditor(_ entry: FSEntry) -> some View {
        HStack(spacing: 8) {
            ForEach(1..<Tag.colorNames.count, id: \.self) { i in
                let name = Tag.colorNames[i]
                let on = entry.tags.contains { $0.name == name }
                Circle().fill(Color.named(name) ?? .secondary)
                    .frame(width: 16, height: 16)
                    .overlay { if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) } }
                    .overlay { Circle().stroke(.secondary.opacity(0.4)) }
                    .onTapGesture { app.toggleColorTag(name: name, colorIndex: i, on: entry) }
            }
        }
        let named = entry.tags.filter { $0.colorName == nil }
        if !named.isEmpty {
            FlowTags(names: named.map(\.name))
        }
        HStack(spacing: 6) {
            TextField("New tag", text: $newTag)
                .textFieldStyle(.roundedBorder)
                .onSubmit { app.addTag(newTag, on: entry); newTag = "" }
            Button("Add") { app.addTag(newTag, on: entry); newTag = "" }
        }
    }

    private func loadMeta(_ entry: FSEntry) async {
        created = (try? entry.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        perms = Self.permString(entry.url)
        folderSize = nil
        if entry.isDirectory {
            let bytes = await Self.directorySize(entry.url)
            folderSize = Self.byteStr(bytes)
        }
    }

    // MARK: helpers

    static func byteStr(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    static func dateStr(_ d: Date) -> String { df.string(from: d) }
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    static func permString(_ url: URL) -> String {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
        else { return "—" }
        let p = n.intValue
        func rwx(_ b: Int) -> String {
            "\(b & 4 != 0 ? "r" : "-")\(b & 2 != 0 ? "w" : "-")\(b & 1 != 0 ? "x" : "-")"
        }
        return rwx((p >> 6) & 7) + rwx((p >> 3) & 7) + rwx(p & 7)
    }

    /// Recursively sums regular-file sizes off the main actor, honouring cancel.
    static func directorySize(_ url: URL) async -> Int64 {
        await Task.detached(priority: .utility) {
            var total: Int64 = 0
            let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
            if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
                while let f = en.nextObject() as? URL {
                    if Task.isCancelled { break }
                    if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                        total += Int64(v.fileSize ?? 0)
                    }
                }
            }
            return total
        }.value
    }
}

/// Simple wrapping row of named (non-color) tag chips.
struct FlowTags: View {
    let names: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(names, id: \.self) { n in
                Text(n).font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
            }
        }
    }
}
