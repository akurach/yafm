import SwiftUI
import AppKit
import Core
import UniformTypeIdentifiers
import ImageIO

// MARK: - Right inspector: Info / Preview modes (§4)

struct InspectorView: View {
    @Bindable var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Picker("", selection: $app.inspectorMode) {
                    Text("Info").tag(AppState.InspectorMode.info)
                    Text("Preview").tag(AppState.InspectorMode.preview)
                }
                .pickerStyle(.segmented).labelsHidden()
                Spacer()
                Button { app.showPreview = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close inspector")
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
            switch app.inspectorMode {
            case .info: InfoPanel(app: app, tab: app.activeTab)
            case .preview: PreviewPane(tab: app.activeTab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onExitCommand { app.showPreview = false }
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
    @State private var imageMeta: [(label: String, value: String)] = []

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
            if !imageMeta.isEmpty {
                Divider()
                Text("Image").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(imageMeta, id: \.label) { row in field(row.label, row.value) }
            }
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
                    .frame(width: Theme.Col.tagDotLarge, height: Theme.Col.tagDotLarge)
                    .overlay { if on { Image(systemName: "checkmark").font(Theme.Font.micro.bold()).foregroundStyle(.white) } }
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
        imageMeta = []
        if entry.isDirectory {
            let bytes = await app.fs.directorySize(of: entry.url)
            folderSize = Self.byteStr(bytes)
        } else {
            imageMeta = await Task.detached(priority: .utility) {
                Self.readImageMeta(from: entry.url)
            }.value
        }
    }

    nonisolated private static func readImageMeta(from url: URL) -> [(label: String, value: String)] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }

        // Try per-image properties at primary index first; for multi-image HEIF
        // containers (e.g. Sony .HIF) the primary image may not be at index 0 —
        // fall back to container-level properties.
        var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        if props == nil {
            props = CGImageSourceCopyProperties(src, nil) as? [String: Any]
        }
        guard let p = props else { return [] }

        var rows: [(String, String)] = []

        if let w = p[kCGImagePropertyPixelWidth as String] as? Int,
           let h = p[kCGImagePropertyPixelHeight as String] as? Int {
            rows.append(("Dimensions", "\(w) × \(h)"))
        }

        if let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            if let make  = tiff[kCGImagePropertyTIFFMake  as String] as? String { rows.append(("Make",  make))  }
            if let model = tiff[kCGImagePropertyTIFFModel as String] as? String { rows.append(("Model", model)) }
        }

        if let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let fn  = exif[kCGImagePropertyExifFNumber as String]        as? Double { rows.append(("F-number",  "f/\(fn)")) }
            if let fl  = exif[kCGImagePropertyExifFocalLength as String]    as? Double { rows.append(("Focal length", "\(Int(fl)) mm")) }
            if let exp = exif[kCGImagePropertyExifExposureTime as String]   as? Double {
                // Format as fraction if < 1 s (e.g. 0.005 → 1/200)
                let str = exp < 1 ? "1/\(Int((1 / exp).rounded()))" : String(format: "%.1f s", exp)
                rows.append(("Exposure", str))
            }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first { rows.append(("ISO", "\(iso)")) }
            if let d   = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String { rows.append(("Date taken", d)) }
        }

        return rows
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

/// Wrapping row of named (non-color) tag chips — real flow layout so many tags
/// wrap to the next line instead of overflowing the inspector (design audit).
struct FlowTags: View {
    let names: [String]
    var body: some View {
        FlowLayout(spacing: Theme.Space.tight) {
            ForEach(names, id: \.self) { n in
                Text(n).font(.caption2)
                    .padding(.horizontal, Theme.Space.pane).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.Palette.controlFill))
            }
        }
    }
}
