import SwiftUI
import Core

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

    // No own background / height — the bar lives in the shared bottom band
    // (status line + F-keys), which paints FunctionBarBackground and sets height.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
    }

    // Full-width keys sharing the bar equally — wide, stable mouse/visual targets
    // (the TC convention). Separated by a hover pill, not drawn dividers; the pill
    // is inset so adjacent keys read as distinct without a "fence". ViewThatFits
    // drops the labels (keeping the F-number anchors) when the window is narrow.
    private func bar(compact: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                FunctionKeyButton(number: k.0, label: k.1, compact: compact) { app.run(k.2) }
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct FunctionBarBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { Theme.Palette.functionBar(scheme == .dark) }
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
                // The F-number is the muscle-memory anchor — promote it to the
                // strongest glyph in the key (mono, near-primary); the label is the
                // quieter gloss beside it.
                Text("F\(number)").font(Theme.Font.badge).foregroundStyle(.primary).opacity(0.9)
                if !compact { Text(label).font(IBMPlex.sans(12)).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity)   // fill the cell → equal width + full hit area
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(FunctionKeyStyle(hover: hover))
        .onHover { hover = $0 }
    }
}

/// Hover paints a calm 5pt pill; an actual press flashes accent — feedback the
/// old full-cell wash lacked. The pill is inset (3pt) from the cell edges so
/// neighbouring full-width keys read as distinct without a drawn divider.
private struct FunctionKeyStyle: ButtonStyle {
    let hover: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? Theme.Palette.controlHover
                          : hover ? Theme.Palette.controlFill : Color.clear)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
            )
    }
}
