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
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
        // Slightly darker than chrome so the bottom strip reads as its own zone.
        .background(FunctionBarBackground())
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(keys.enumerated()), id: \.offset) { idx, k in
                FunctionKeyButton(number: k.0, label: k.1, compact: compact) { app.run(k.2) }
                if idx < keys.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
    }
}

struct FunctionBarBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        scheme == .dark
            ? Color(red: 0.090, green: 0.090, blue: 0.098)   // slightly lighter than #111113
            : Color(red: 0.820, green: 0.820, blue: 0.828)   // #d1d1d3 — darker than chrome
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
                Text("F\(number)").font(IBMPlex.sans(10, weight: .semibold)).foregroundStyle(.secondary)
                if !compact { Text(label).font(IBMPlex.sans(12)) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(hover ? Color.primary.opacity(0.10) : Color.clear)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hover = $0 }
    }
}
