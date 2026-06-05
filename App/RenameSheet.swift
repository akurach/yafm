import SwiftUI
import AppKit
import Core

/// A text field that, on appear, focuses and selects the **basename** (the part
/// before the last dot) — so renaming `report.final.pdf` lets you type over the
/// name without clobbering the extension (UX audit). Falls back to selecting all
/// for dotfiles / extensionless names.
struct BasenameField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        // Select the basename once, after the name has been seeded (avoids the
        // initial-empty race) — focus + select on the next runloop tick.
        guard !context.coordinator.didSelect, !text.isEmpty else { return }
        context.coordinator.didSelect = true
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
            guard let editor = nsView.currentEditor() else { return }
            let ns = text as NSString
            let dot = ns.range(of: ".", options: .backwards)
            editor.selectedRange = (dot.location == NSNotFound || dot.location == 0)
                ? NSRange(location: 0, length: ns.length)
                : NSRange(location: 0, length: dot.location)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: BasenameField
        var didSelect = false
        init(_ parent: BasenameField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSTextField { parent.text = f.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            return false
        }
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
                BasenameField(text: $replacement, onSubmit: { apply(names); dismiss() })
                    .frame(height: 22)
                    .onAppear { if replacement.isEmpty { replacement = names.first ?? "" } }
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
