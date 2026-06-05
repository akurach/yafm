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

    // The List is the only child and fills the pane natively; the column header
    // rides along as a pinned Section header (a plain List inside a VStack would
    // collapse to its intrinsic height and float mid-pane). Bonus: header and
    // rows share the List's insets, so columns line up.
    private var rows: some View {
        ScrollViewReader { proxy in
            List {
                Section {
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
                                app.activePaneIsLeft = tabBelongsToLeft()
                            }
                            .contextMenu { rowMenu(entry) }
                    }
                } header: {
                    columnHeader
                }
            }
            .contextMenu { backgroundMenu() }   // empty area below the rows
            .listStyle(.inset)
            .onChange(of: tab.cursor) { _, new in
                if let new { withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) } }
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
        Button(role: .destructive) { focus(entry); app.run(CommandID.delete) } label: { Label("Delete", systemImage: "trash") }

        Divider()
        Menu {
            ForEach(1..<Tag.colorNames.count, id: \.self) { i in
                let name = Tag.colorNames[i]
                let on = entry.tags.contains { $0.name == name }
                Button { app.toggleColorTag(name: name, colorIndex: i, on: entry) } label: {
                    Label(name, systemImage: on ? "checkmark.circle.fill" : "circle")
                }
            }
            Divider()
            Button("New Tag…") { app.promptNewTag(on: entry) }
        } label: { Label("Tags", systemImage: "tag") }

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
