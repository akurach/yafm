import SwiftUI
import AppKit
import Core
import UniformTypeIdentifiers

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
        // Go through the provider — never reach past it to FileManager — so the
        // inspector works under a virtual FS (FTP/SMB) instead of returning 0.
        let detail = await app.fs.detail(of: entry.url)
        created = detail.created
        perms = detail.permissions
        folderSize = nil
        if entry.isDirectory {
            let bytes = await app.fs.directorySize(of: entry.url)
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
