import SwiftUI
import AppKit
import Core

// MARK: - Compress modal (format · level · solid · password · split · ignore · after)

/// Modal for **Compress** — the full per-action dialog (format, level, solid
/// block, password, split-into-volumes, ignore rules, save location, and what to
/// do with the originals). Drives `AppState.performCompress`.
struct CompressSheet: View {
    let app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var format: ArchiveService.CompressionFormat = .zip
    @State private var level = 6
    @State private var password = ""
    @State private var name = "Archive"
    @State private var solid = false
    @State private var split = false
    @State private var volumeMB = 100
    @State private var ignoreHidden = false
    @State private var ignoreVCS = false
    @State private var trashOriginals = false
    @State private var saveDir: URL? = nil

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
                    Text("Save to").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack {
                        Text(saveDir?.lastPathComponent ?? "Same folder").lineLimit(1).foregroundStyle(.secondary)
                        Button("Choose…") { chooseSaveDir() }
                        if saveDir != nil { Button("Reset") { saveDir = nil }.buttonStyle(.borderless) }
                    }
                }
                GridRow {
                    Text("Format").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Picker("", selection: $format) {
                            ForEach(ArchiveService.availableFormats) { Text($0.label).tag($0) }
                        }.labelsHidden().fixedSize()
                        if format == .sevenZip {
                            Toggle("Solid", isOn: $solid).toggleStyle(.checkbox)
                                .help("Better ratio; the whole archive decompresses as one block")
                        }
                    }
                }
                GridRow {
                    Text("Compression").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack {
                        Slider(value: Binding(get: { Double(level) },
                                              set: { level = Int($0.rounded()) }), in: 0...9, step: 1)
                            .frame(width: 160)
                            .disabled(!format.supportsLevel)
                        Text(levelLabel).foregroundStyle(.secondary).font(.caption).frame(width: 80, alignment: .leading)
                    }
                }
                GridRow {
                    Text("Password").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        SecureField(format.supportsPassword ? "optional" : "ZIP / 7z only", text: $password)
                            .textFieldStyle(.roundedBorder).frame(width: 200)
                            .disabled(!format.supportsPassword)
                        if format == .zip && !password.isEmpty {
                            Text("ZIP uses legacy (weak) encryption — 7z is AES-256").font(.caption2).foregroundStyle(.tertiary)
                        } else if format == .sevenZip && !password.isEmpty {
                            Text("7z: AES-256, encrypted file names").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                GridRow {
                    Text("Split").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Toggle("Into volumes of", isOn: $split).toggleStyle(.checkbox)
                            .disabled(!splitSupported)
                        TextField("100", value: $volumeMB, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 56)
                            .disabled(!split || !splitSupported)
                        Text("MB").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Ignore").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Toggle("Hidden", isOn: $ignoreHidden).toggleStyle(.checkbox)
                        Toggle(".git / .svn", isOn: $ignoreVCS).toggleStyle(.checkbox)
                    }
                }
                GridRow {
                    Text("After").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    Toggle("Move originals to Trash", isOn: $trashOriginals).toggleStyle(.checkbox)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { name = app.compressBaseName }
        .onChange(of: format) { _, f in
            if !f.supportsPassword { password = "" }
            if !splitSupported { split = false }
        }
    }

    private var splitSupported: Bool { format == .zip || format == .sevenZip }

    private func create() {
        app.compressBaseName = name.isEmpty ? "Archive" : name
        let opts = ArchiveService.CompressOptions(
            format: format, level: level,
            password: format.supportsPassword ? password : nil,
            solid: solid,
            volumeSizeMB: (split && splitSupported && volumeMB > 0) ? volumeMB : nil,
            excludeHidden: ignoreHidden, excludeVCS: ignoreVCS)
        app.performCompress(options: opts, saveDir: saveDir, trashOriginals: trashOriginals)
    }

    private func chooseSaveDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { saveDir = panel.url }
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
