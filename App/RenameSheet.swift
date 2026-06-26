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

// MARK: - Editable rename step (UI draft over Core's RenameStep)

/// A mutable, identifiable wrapper around `Core.RenameStep` so the bulk-rename
/// sheet can edit a chain of rules with SwiftUI bindings. `step` projects the
/// draft into the pure Core value the pipeline consumes.
private struct StepDraft: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case findReplace   = "Find & Replace"
        case lowercase     = "lowercase"
        case replaceSpaces = "Replace spaces"
        case sequence      = "Number sequentially"
        var id: String { rawValue }
    }
    let id = UUID()
    var kind: Kind
    var pattern = ""
    var replacement = ""
    var useRegex = false
    var separator = "-"
    var seqStart = 1

    var step: RenameStep {
        switch kind {
        case .findReplace:   return .findReplace(pattern: pattern, replacement: replacement, useRegex: useRegex)
        case .lowercase:     return .lowercase
        case .replaceSpaces: return .replaceSpaces(separator: separator)
        case .sequence:      return .sequence(start: seqStart, width: 2)
        }
    }
}

// MARK: - Rename sheet (v0.1 single + v0.2 bulk preview + v0.9.8 chained rules)

struct RenameSheet: View {
    let app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var replacement = ""
    @State private var bulk = false
    @State private var steps: [StepDraft] = [StepDraft(kind: .findReplace)]
    /// Per-row manual overrides, keyed by the original name (unique within a
    /// folder). When present, the typed value wins over the rule pipeline for
    /// that one file — the "fix this single name by hand" escape hatch.
    @State private var overrides: [String: String] = [:]

    var body: some View {
        let names = app.activeTab.actionable.map(\.name)
        VStack(alignment: .leading, spacing: 10) {
            Text(bulk ? "Bulk Rename (\(names.count))" : "Rename").font(.headline)
            Toggle("Bulk rename", isOn: $bulk).disabled(names.count < 2 && !bulk)

            if bulk {
                bulkEditor(names: names)
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
        .frame(width: 480)
    }

    // MARK: Bulk editor — a chain of rules applied left-to-right

    @ViewBuilder
    private func bulkEditor(names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($steps) { $draft in
                HStack(spacing: 6) {
                    Picker("", selection: $draft.kind) {
                        ForEach(StepDraft.Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)

                    stepFields($draft)

                    Spacer(minLength: 0)
                    Button {
                        steps.removeAll { $0.id == draft.id }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(steps.count <= 1)
                }
            }

            Menu {
                ForEach(StepDraft.Kind.allCases) { kind in
                    Button(kind.rawValue) { steps.append(StepDraft(kind: kind)) }
                }
            } label: {
                Label("Add rule", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider()

            let preview = RenamePipeline(steps: steps.map(\.step)).preview(names)
            Text("Edit any target to override that row.").font(.caption2).foregroundStyle(.tertiary)
            ScrollView {
                ForEach(Array(preview.enumerated()), id: \.offset) { _, pair in
                    let overridden = overrides[pair.from] != nil
                    let target = Binding(
                        get: { overrides[pair.from] ?? pair.to },
                        set: { overrides[pair.from] = $0 }
                    )
                    HStack(spacing: 6) {
                        Text(pair.from).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2)
                        TextField("", text: target)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .foregroundStyle(overridden ? Color.accentColor
                                             : (pair.from == (overrides[pair.from] ?? pair.to) ? .secondary : .primary))
                        if overridden {
                            Button { overrides[pair.from] = nil } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderless).help("Revert to rule output")
                        }
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(height: 140)
        }
    }

    @ViewBuilder
    private func stepFields(_ draft: Binding<StepDraft>) -> some View {
        switch draft.wrappedValue.kind {
        case .findReplace:
            TextField("Find", text: draft.pattern).textFieldStyle(.roundedBorder).frame(width: 90)
            TextField("Replace (# = counter)", text: draft.replacement).textFieldStyle(.roundedBorder)
            Toggle("regex", isOn: draft.useRegex).toggleStyle(.checkbox)
        case .replaceSpaces:
            Text("with").foregroundStyle(.secondary).font(.caption)
            TextField("-", text: draft.separator).textFieldStyle(.roundedBorder).frame(width: 50)
        case .sequence:
            Text("start").foregroundStyle(.secondary).font(.caption)
            Stepper("\(draft.wrappedValue.seqStart)", value: draft.seqStart, in: 0...9999)
        case .lowercase:
            EmptyView()
        }
    }

    private func apply(_ names: [String]) {
        if bulk {
            let plan = RenamePipeline(steps: steps.map(\.step)).preview(names)
            for (entry, pair) in zip(app.activeTab.actionable, plan) {
                let target = (overrides[pair.from] ?? pair.to).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !target.isEmpty, target != pair.from else { continue }
                app.rename(entry: entry, to: target)
            }
        } else {
            app.rename(to: replacement)
        }
    }
}
