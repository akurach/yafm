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
            .padding(.horizontal, Theme.Space.row).padding(.vertical, Theme.Space.tight)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(hover ? Theme.Palette.controlHover : Theme.Palette.controlFill)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
