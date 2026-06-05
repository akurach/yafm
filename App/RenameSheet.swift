import SwiftUI
import Core

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
