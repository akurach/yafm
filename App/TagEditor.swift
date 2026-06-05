import SwiftUI
import AppKit
import Core

// MARK: - Custom tag editor (replaces the Finder-style nested checkbox menu)

/// A proper tag UI: big color swatches you toggle, your existing free-form tags
/// as removable chips, and an inline field to add a new one. Opened from the row
/// context menu's "Tags…" item. Writes the whole tag set on every change.
struct TagEditorSheet: View {
    let app: AppState
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var tags: [Tag] = []
    @State private var newTag = ""
    @FocusState private var fieldFocused: Bool

    private var colorNames: [String] { Array(Tag.colorNames.dropFirst()) }   // drop "None"
    private var named: [Tag] { tags.filter { $0.colorName == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Text("COLOR").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            swatches

            Text("TAGS").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            chips
            addField

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
        .task { tags = await app.currentTags(of: url) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 36, height: 36)
            Text(url.lastPathComponent).font(.headline).lineLimit(1)
            Spacer()
        }
    }

    // Tappable color dots; a ring + check marks the active ones.
    private var swatches: some View {
        HStack(spacing: 12) {
            ForEach(Array(colorNames.enumerated()), id: \.element) { offset, name in
                let on = tags.contains { $0.name == name }
                Circle()
                    .fill(Color.named(name) ?? .secondary)
                    .frame(width: 26, height: 26)
                    .overlay {
                        if on {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .overlay {
                        Circle().stroke(on ? Color.primary.opacity(0.5) : Color.primary.opacity(0.12),
                                        lineWidth: on ? 2 : 1)
                    }
                    .contentShape(Circle())
                    .onTapGesture { toggleColor(name: name, index: offset + 1) }
                    .help(name)
            }
        }
    }

    // Existing free-form tags as removable chips.
    @ViewBuilder
    private var chips: some View {
        if named.isEmpty {
            Text("No tags yet").font(.caption).foregroundStyle(.tertiary)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(named, id: \.name) { tag in
                    HStack(spacing: 4) {
                        Text(tag.name).font(.caption)
                        Button { remove(tag) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
                }
            }
        }
    }

    private var addField: some View {
        HStack(spacing: 6) {
            TextField("Add a tag…", text: $newTag)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(add)
            Button("Add", action: add).disabled(trimmed.isEmpty)
        }
        .onAppear { fieldFocused = true }
    }

    private var trimmed: String { newTag.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: mutations (optimistic local state + persist whole set)

    private func toggleColor(name: String, index: Int) {
        if let i = tags.firstIndex(where: { $0.name == name }) { tags.remove(at: i) }
        else { tags.append(Tag(name: name, colorIndex: index)) }
        persist()
    }

    private func add() {
        let t = trimmed
        guard !t.isEmpty, !t.contains("\n"), !tags.contains(where: { $0.name == t }) else { return }
        tags.append(Tag(name: t))
        newTag = ""
        persist()
    }

    private func remove(_ tag: Tag) {
        tags.removeAll { $0.name == tag.name }
        persist()
    }

    private func persist() { app.writeTags(tags, on: url) }
}

// MARK: - Minimal flow layout for wrapping chips

/// Wraps children onto new lines when they overflow the width. Tiny, no deps —
/// SwiftUI has no built-in flow layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
