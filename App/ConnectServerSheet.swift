import SwiftUI
import Core

/// Connect to Server (⌘⇧K) — type an `smb://` address; yafm mounts it natively
/// behind the filesystem router and opens it in the active pane like any folder.
/// A failed connection surfaces as a `.failed` listing (the unified state-view),
/// never a frozen window.
struct ConnectServerSheet: View {
    @Bindable var app: AppState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Server").font(.headline)
            Text("Enter a server address. SMB shares mount natively — macOS handles credentials (Keychain).")
                .font(.caption).foregroundStyle(.secondary)
            TextField("smb://server/share", text: $app.connectAddress)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .focused($focused)
                .onSubmit(connect)
            HStack {
                Text("Example: smb://nas.local/Media")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { app.connectSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { focused = true }
    }

    private var isValid: Bool {
        guard let url = URL(string: app.connectAddress.trimmingCharacters(in: .whitespaces)) else { return false }
        return url.scheme != nil && url.host != nil
    }

    private func connect() { app.connectToServer(app.connectAddress) }
}
