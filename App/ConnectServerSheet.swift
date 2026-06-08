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

            if hasEmbeddedPassword {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("URL contains a password. macOS Keychain is safer — remove credentials from the URL.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if !app.settings.recentServers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent").font(.caption).foregroundStyle(.secondary)
                    ForEach(app.settings.recentServers, id: \.self) { server in
                        Button {
                            app.connectAddress = server
                        } label: {
                            Text(displayAddress(server))
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

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

    private var hasEmbeddedPassword: Bool {
        URL(string: app.connectAddress.trimmingCharacters(in: .whitespaces))?.password != nil
    }

    /// Show recents with password redacted so the list isn't a credential dump.
    private func displayAddress(_ raw: String) -> String {
        guard var comps = URLComponents(string: raw), comps.password != nil else { return raw }
        comps.password = "••••"
        return comps.string ?? raw
    }

    private func connect() { app.connectToServer(app.connectAddress) }
}
