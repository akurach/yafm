import SwiftUI
import AppKit
import Core

// MARK: - Custom tag editor (replaces the Finder-style nested checkbox menu)

/// A proper tag UI: big color swatches you toggle, your existing free-form tags
/// as removable chips, and an inline field to add a new one. Opened from the row
/// context menu's "Tags…" item over the selection (1 file = single, 2+ = batch).
///
/// Batch semantics: a swatch/chip reads from a per-name *membership count* over
/// the selection — full (every file carries it), mixed (some do), or off. Tapping
/// a full one removes the tag from all; tapping an off/mixed one adds it to all.
/// Writes go through `app.batchTag`, which is a single-file no-op-safe pass, so a
/// one-file selection behaves exactly as the old single-file editor did.
struct TagEditorSheet: View {
    let app: AppState
    let urls: [URL]

    @Environment(\.dismiss) private var dismiss
    /// name -> how many of `urls` carry the tag (0…urls.count).
    @State private var membership: [String: Int] = [:]
    @State private var colorIdx: [String: Int] = [:]
    @State private var newTag = ""
    @FocusState private var fieldFocused: Bool

    private var total: Int { urls.count }
    private var colorNames: [String] { Array(Tag.colorNames.dropFirst()) }   // drop "None"
    /// Named (non-color) tags present on at least one file, with their count.
    private var named: [(name: String, count: Int)] {
        membership
            .filter { name, count in count > 0 && !colorNames.contains(name) }
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.name < $1.name }
    }

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
        .task {
            let m = await app.tagMembership(of: urls)
            membership = m.counts
            colorIdx = m.colorIndex
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if total == 1, let url = urls.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 36, height: 36)
                Text(url.lastPathComponent).font(.headline).lineLimit(1)
            } else {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 26)).foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                Text("\(total) items").font(.headline)
            }
            Spacer()
        }
    }

    // MARK: membership → swatch/chip state

    private enum Fill { case off, mixed, full }
    private func fill(_ name: String) -> Fill {
        let c = membership[name] ?? 0
        if c == 0 { return .off }
        return c >= total ? .full : .mixed
    }

    // Tappable color dots; a ring + check (full) or dash (mixed) marks state.
    private var swatches: some View {
        HStack(spacing: 12) {
            ForEach(Array(colorNames.enumerated()), id: \.element) { offset, name in
                let state = fill(name)
                Circle()
                    .fill(Color.named(name) ?? .secondary)
                    .frame(width: 26, height: 26)
                    .overlay {
                        switch state {
                        case .full:
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        case .mixed:
                            Image(systemName: "minus")
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        case .off:
                            EmptyView()
                        }
                    }
                    .overlay {
                        Circle().stroke(state == .off ? Color.primary.opacity(0.12) : Color.primary.opacity(0.5),
                                        lineWidth: state == .off ? 1 : 2)
                    }
                    .contentShape(Circle())
                    .onTapGesture { toggleColor(name: name, index: offset + 1) }
                    .help(state == .mixed ? "\(name) (some)" : name)
            }
        }
    }

    // Existing free-form tags as removable chips; a count badge when mixed.
    @ViewBuilder
    private var chips: some View {
        if named.isEmpty {
            Text("No tags yet").font(.caption).foregroundStyle(.tertiary)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(named, id: \.name) { tag in
                    HStack(spacing: 4) {
                        Text(tag.name).font(.caption)
                        if total > 1 && tag.count < total {
                            Text("\(tag.count)/\(total)").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        Button { removeNamed(tag.name) } label: {
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

    // MARK: mutations (optimistic local count + batch persist)

    private func toggleColor(name: String, index: Int) {
        // Full → clear from all; off or mixed → apply to all.
        let add = fill(name) != .full
        membership[name] = add ? total : 0
        if add { colorIdx[name] = index }
        app.batchTag(name: name, colorIndex: index, add: add, on: urls)
    }

    private func add() {
        let t = trimmed
        guard !t.isEmpty, !t.contains("\n") else { return }
        membership[t] = total
        newTag = ""
        app.batchTag(name: t, colorIndex: nil, add: true, on: urls)
    }

    private func removeNamed(_ name: String) {
        membership[name] = 0
        app.batchTag(name: name, colorIndex: colorIdx[name], add: false, on: urls)
    }
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
