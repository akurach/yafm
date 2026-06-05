import SwiftUI
import AppKit
import Observation
import Core

// MARK: - Persisted app settings (v0.2.3 app shell)

/// Theme choice. `system` (default) follows the OS appearance.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Where new windows start.
enum StartMode: String, CaseIterable, Identifiable {
    case home, lastUsed, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .home: "Home"
        case .lastUsed: "Last used"
        case .custom: "Specific folder"
        }
    }
}

/// User settings, backed by `UserDefaults` (same store as the `didOnboard` flag).
/// `@Observable` so the UI and `AppState` both react; each `didSet` persists.
/// Settings must change real behaviour — no decorative toggles.
@Observable
final class AppSettings {
    /// → (right arrow) on a **file**: by default it only enters folders and does
    /// nothing on files. Turn on to also open files (Enter always opens).
    var rightArrowOpensFiles: Bool { didSet { store.set(rightArrowOpensFiles, forKey: Keys.rightArrowOpensFiles) } }

    /// New tabs/panes start with hidden files shown.
    var showHiddenByDefault: Bool { didSet { store.set(showHiddenByDefault, forKey: Keys.showHiddenByDefault) } }

    /// Light / Dark / System.
    var theme: AppTheme { didSet { store.set(theme.rawValue, forKey: Keys.theme) } }

    /// Start folder for new windows.
    var startMode: StartMode { didSet { store.set(startMode.rawValue, forKey: Keys.startMode) } }
    var customStartPath: String { didSet { store.set(customStartPath, forKey: Keys.customStartPath) } }

    /// Confirm before the (permanent) delete.
    var confirmBeforeDelete: Bool { didSet { store.set(confirmBeforeDelete, forKey: Keys.confirmBeforeDelete) } }

    /// Default behaviour when copy/move hits an existing file.
    var collisionDefault: CollisionPolicy { didSet { store.set(collisionDefault.rawValue, forKey: Keys.collisionDefault) } }

    @ObservationIgnored private let store = UserDefaults.standard

    private enum Keys {
        static let rightArrowOpensFiles = "rightArrowOpensFiles"
        static let showHiddenByDefault = "showHiddenByDefault"
        static let theme = "theme"
        static let startMode = "startMode"
        static let customStartPath = "customStartPath"
        static let lastFolder = "lastFolder"
        static let confirmBeforeDelete = "confirmBeforeDelete"
        static let collisionDefault = "collisionDefault"
    }

    init() {
        let d = UserDefaults.standard
        rightArrowOpensFiles = d.bool(forKey: Keys.rightArrowOpensFiles)   // default false → folders only
        showHiddenByDefault = d.bool(forKey: Keys.showHiddenByDefault)
        theme = AppTheme(rawValue: d.string(forKey: Keys.theme) ?? "") ?? .system
        startMode = StartMode(rawValue: d.string(forKey: Keys.startMode) ?? "") ?? .home
        customStartPath = d.string(forKey: Keys.customStartPath) ?? ""
        // Permanent delete: confirm by default unless the user has explicitly set it.
        confirmBeforeDelete = d.object(forKey: Keys.confirmBeforeDelete) as? Bool ?? true
        collisionDefault = CollisionPolicy(rawValue: d.string(forKey: Keys.collisionDefault) ?? "") ?? .keepBoth
    }

    /// Directory new windows open at, falling back to Home when a path is gone.
    func startDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func valid(_ path: String) -> URL? {
            var isDir: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue
            else { return nil }
            return URL(fileURLWithPath: path)
        }
        switch startMode {
        case .home: return home
        case .lastUsed: return valid(store.string(forKey: Keys.lastFolder) ?? "") ?? home
        case .custom: return valid(customStartPath) ?? home
        }
    }

    /// Remember the last browsed folder (used by `.lastUsed`). Cheap; called on
    /// scene-phase change, not per navigation.
    func rememberLastFolder(_ url: URL) { store.set(url.path, forKey: Keys.lastFolder) }
}

// MARK: - Update checker (GitHub Releases, MVP per app-shell.md §2 option 2)

/// Non-blocking "check for updates": query the GitHub Releases API, compare to
/// the bundled version, and on a newer release point the user at the page. No
/// auto-install (that's Sparkle, deferred). Honest status, never silent.
@MainActor
@Observable
final class UpdateChecker {
    enum Status: Equatable {
        case idle, checking, upToDate
        case available(version: String, url: URL)
        case error(String)
    }
    var status: Status = .idle

    private let repo = "akurach/yafm"
    private var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    func check() {
        status = .checking
        Task {
            do {
                let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
                var req = URLRequest(url: url)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
                    status = .upToDate   // no releases published yet
                    return
                }
                let rel = try JSONDecoder().decode(Release.self, from: data)
                let latest = rel.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if latest.compare(current, options: .numeric) == .orderedDescending,
                   let page = URL(string: rel.html_url) {
                    status = .available(version: latest, url: page)
                } else {
                    status = .upToDate
                }
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    private struct Release: Decodable { let tag_name: String; let html_url: String }
}

// MARK: - Settings window (⌘,)

struct SettingsView: View {
    @Bindable var app: AppState
    @State private var updates = UpdateChecker()

    private var settings: AppSettings { app.settings }

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            appearance.tabItem { Label("Appearance", systemImage: "paintbrush") }
            operations.tabItem { Label("Operations", systemImage: "arrow.left.arrow.right") }
            tags.tabItem { Label("Tags", systemImage: "tag") }
            plugins.tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
            updatesTab.tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 500, height: 340)
    }

    private var general: some View {
        Form {
            Section("Start folder") {
                Picker("New windows open at", selection: bindable.startMode) {
                    ForEach(StartMode.allCases) { Text($0.label).tag($0) }
                }
                if settings.startMode == .custom {
                    HStack {
                        Text(settings.customStartPath.isEmpty ? "No folder chosen" : settings.customStartPath)
                            .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { chooseStartFolder() }
                    }
                }
            }
            Section("Navigation") {
                Toggle("Right arrow opens files", isOn: bindable.rightArrowOpensFiles)
                Text("Off (default): → only enters folders. On: → also opens files. Enter always opens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Listing") {
                Toggle("Show hidden files in new tabs", isOn: bindable.showHiddenByDefault)
            }
        }
        .formStyle(.grouped)
    }

    private var appearance: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: bindable.theme) {
                    ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }

    private var operations: some View {
        Form {
            Section("Delete") {
                Toggle("Confirm before deleting", isOn: bindable.confirmBeforeDelete)
                Text("Delete is permanent (not Trash). Keep this on unless you're sure.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Copy / Move collisions") {
                Picker("When a file already exists", selection: bindable.collisionDefault) {
                    Text("Keep both").tag(CollisionPolicy.keepBoth)
                    Text("Skip").tag(CollisionPolicy.skip)
                    Text("Replace").tag(CollisionPolicy.replace)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var tags: some View {
        Form {
            Section("Tag index") {
                Text("The sidebar tag cloud is built from an index of your files. Rescan after tagging outside yafm; clear to rebuild from scratch.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Rescan now") { app.rescanTags() }
                    Button("Clear index") { app.clearTags() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var plugins: some View {
        Form {
            Section("JavaScript plugins") {
                Text("Drop a .js file in the plugins folder to add table columns. Plugins run in a sandbox: no filesystem, network, or process access — only the host API.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open Plugins Folder") { app.revealPluginsFolder() }
                    Button("Reload Plugins") { app.loadPlugins() }
                }
            }
            Section("Loaded") {
                if app.pluginHost.loaded.isEmpty {
                    Text("No plugins loaded.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(app.pluginHost.loaded, id: \.name) { p in
                        HStack {
                            Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.secondary)
                            Text(p.name)
                            Spacer()
                            Text(p.columnTitles.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                ForEach(app.pluginHost.errors, id: \.name) { e in
                    Label("\(e.name): \(e.message)", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var updatesTab: some View {
        Form {
            Section("Updates") {
                HStack {
                    Button("Check for Updates") { updates.check() }
                    Spacer()
                    statusView
                }
                Text("Current version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?").")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var statusView: some View {
        switch updates.status {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Label("Up to date", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .available(let v, let url):
            Button("Get \(v)") { NSWorkspace.shared.open(url) }
        case .error(let m): Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(1)
        }
    }

    private var bindable: Bindable<AppSettings> { Bindable(settings) }

    private func chooseStartFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { settings.customStartPath = url.path }
    }
}
