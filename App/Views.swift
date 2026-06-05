import SwiftUI
import Core

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

    private var rows: some View {
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
                }
            }
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
            Text(entry.name)
                .foregroundStyle(entry.isHidden ? .secondary : .primary)
                .lineLimit(1)
            Spacer()
            ForEach(entry.tags, id: \.name) { tag in
                Circle().fill(Color.named(tag.colorName) ?? .secondary).frame(width: 8, height: 8)
            }
            if let size = entry.size, !entry.isDirectory {
                Text(byteString(size)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

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

// MARK: - Bookmarks sidebar (v0.2)

struct BookmarksSidebar: View {
    let app: AppState

    var body: some View {
        List {
            Section("Favorites") {
                ForEach(app.bookmarks) { bm in
                    Label(bm.name, systemImage: "folder")
                        .onTapGesture { app.activeTab.open(bm.url) }
                }
            }
        }
        .frame(minWidth: 150, maxWidth: 200)
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
