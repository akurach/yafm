import SwiftUI
import Core

// MARK: - Compress modal (choose format · level · password)

/// Modal for **Compress**: pick the archive format, compression level, optional
/// password (zip only), and the output name. Drives `AppState.performCompress`.
struct CompressSheet: View {
    let app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var format: ArchiveService.CompressionFormat = .zip
    @State private var level = 6
    @State private var password = ""
    @State private var name = "Archive"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(app.compressItems.count == 1
                 ? "Compress \"\(app.compressItems[0].lastPathComponent)\""
                 : "Compress \(app.compressItems.count) items")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("Archive", text: $name).textFieldStyle(.roundedBorder)
                        Text(".\(format.fileExtension)").foregroundStyle(.secondary).font(.callout)
                    }
                }
                GridRow {
                    Text("Format").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Picker("", selection: $format) {
                        ForEach(ArchiveService.CompressionFormat.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                GridRow {
                    Text("Compression").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack {
                        Slider(value: Binding(get: { Double(level) },
                                              set: { level = Int($0.rounded()) }), in: 0...9, step: 1)
                            .frame(width: 160)
                            .disabled(!format.supportsLevel)
                        Text(levelLabel).foregroundStyle(.secondary).font(.caption).frame(width: 72, alignment: .leading)
                    }
                }
                GridRow {
                    Text("Password").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        SecureField(format.supportsPassword ? "optional" : "ZIP only", text: $password)
                            .textFieldStyle(.roundedBorder).frame(width: 200)
                            .disabled(!format.supportsPassword)
                        if format.supportsPassword && !password.isEmpty {
                            Text("ZIP uses legacy (weak) encryption").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    app.compressBaseName = name.isEmpty ? "Archive" : name
                    app.performCompress(format: format, level: level,
                                        password: format.supportsPassword ? password : "")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { name = app.compressBaseName }
        .onChange(of: format) { _, f in if !f.supportsPassword { password = "" } }
    }

    private var levelLabel: String {
        if !format.supportsLevel { return "default" }
        switch level {
        case 0: return "store (0)"
        case 1...3: return "fast (\(level))"
        case 7...9: return "max (\(level))"
        default: return "normal (\(level))"
        }
    }
}

// MARK: - Extract password prompt

/// Raised when an archive is encrypted: collect the password and retry the
/// extraction. Bound to `AppState.extractPasswordPrompt`.
struct ExtractPasswordSheet: View {
    let app: AppState
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Password-protected archive", systemImage: "lock.fill").font(.headline)
            if let url = app.extractPasswordPrompt {
                Text(url.lastPathComponent).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(submit)
            if app.extractPasswordWrong {
                Text("Incorrect password — try again.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { app.extractPasswordPrompt = nil; app.archivePassword = "" }
                Button("Extract") { submit() }.keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        app.archivePassword = password
        app.submitExtractPassword()
    }
}
