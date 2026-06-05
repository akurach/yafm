import SwiftUI
import Core

/// Find-within-folder (⌘F). Submits a name search scoped to the active tab's
/// directory; results replace the listing as a virtual "Search: …" view.
struct SearchSheet: View {
    @Bindable var app: AppState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search in \(app.activeTab.directory.lastPathComponent.isEmpty ? "/" : app.activeTab.directory.lastPathComponent)")
                .font(.headline)
            TextField("File name contains…", text: $app.searchQuery)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(run)
            HStack {
                Text("Spotlight, with a name-scan fallback.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { app.searchSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Search", action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func run() {
        let q = app.searchQuery
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        app.searchSheet = false
        app.runSearch(q)
    }
}
