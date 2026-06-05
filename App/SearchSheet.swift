import SwiftUI
import Core

/// Find-within-folder (⌘F) — an **inline** bar (v0.6) docked under the path bar
/// of the active pane, not a modal. Modal search stole keyboard focus and broke
/// the type-ahead flow; inline keeps you in the file list. Toggles name vs
/// contents (grep), shows a live "Searching…" state, and submits scoped to the
/// active tab's directory; hits replace the listing as a virtual results view.
struct SearchBar: View {
    @Bindable var app: AppState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)

            Picker("", selection: $app.searchMode) {
                Text("Name").tag(SearchMode.name)
                Text("Contents").tag(SearchMode.content)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            TextField(app.searchMode == .content ? "Text in files…" : "File name contains…",
                      text: $app.searchQuery)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .focused($focused)
                .onSubmit(run)

            if app.searchRunning {
                ProgressView().controlSize(.small)
                Text("Searching… \(app.searchHitCount)")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize()
            } else if app.activeTab.virtualOrigin != nil {
                Text("\(app.searchHitCount) found")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize()
            }

            Button("Search", action: run)
                .controlSize(.small)
                .disabled(app.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            Button { app.cancelSearch() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.bar)
        .onAppear { focused = true }
        // Re-focus whenever the bar is re-shown (⌘F while closed).
        .onChange(of: app.searchActive) { _, active in if active { focused = true } }
    }

    private func run() {
        guard !app.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        app.runSearch(app.searchQuery)
    }
}
