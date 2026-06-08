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

/// UI language. `system` follows the OS; the others override via the standard
/// `AppleLanguages` default, which takes effect on the next launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ru
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .en: "English"
        case .ru: "Русский"
        }
    }
    /// Codes to write into `AppleLanguages`, or nil to clear the override.
    var codes: [String]? {
        switch self {
        case .system: nil
        case .en: ["en"]
        case .ru: ["ru"]
        }
    }
}

/// Row density for the file table. Power users want more rows on screen than
/// Finder's single fixed height; `cozy` is the default middle ground.
enum Density: String, CaseIterable, Identifiable {
    case compact, cozy, comfortable
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Extra vertical padding per row half-edge (points). Drives row height.
    var rowPadding: CGFloat {
        switch self {
        case .compact: 1
        case .cozy: 3
        case .comfortable: 6
        }
    }
    /// Row font — compact shrinks a notch to pack more in.
    var rowFont: SwiftUI.Font {
        switch self {
        case .compact: .callout
        case .cozy, .comfortable: .body
        }
    }
    /// Icon box size, scaled with density.
    var iconSize: CGFloat {
        switch self {
        case .compact: 14
        case .cozy: 16
        case .comfortable: 18
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

    /// Row density (Compact / Cozy / Comfortable).
    var density: Density { didSet { store.set(density.rawValue, forKey: Keys.density) } }

    /// UI language. Writing it updates `AppleLanguages` (effective next launch).
    var language: AppLanguage {
        didSet {
            store.set(language.rawValue, forKey: Keys.language)
            if let codes = language.codes { store.set(codes, forKey: "AppleLanguages") }
            else { store.removeObject(forKey: "AppleLanguages") }
        }
    }

    /// Animate selection/navigation glide. Off = instant (some power users
    /// prefer zero motion); streaming row inserts stay un-animated either way.
    var animations: Bool { didSet { store.set(animations, forKey: Keys.animations) } }

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
        static let density = "density"
        static let language = "language"
        static let animations = "animations"
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
        density = Density(rawValue: d.string(forKey: Keys.density) ?? "") ?? .cozy
        language = AppLanguage(rawValue: d.string(forKey: Keys.language) ?? "") ?? .system
        animations = d.object(forKey: Keys.animations) as? Bool ?? true   // default on
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
            Section("Language") {
                Picker("Language", selection: bindable.language) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
                Text("Takes effect after you quit and reopen yafm.")
                    .font(.caption).foregroundStyle(.secondary)
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
            Section("Density") {
                Picker("Row density", selection: bindable.density) {
                    ForEach(Density.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Compact packs more rows on screen; Comfortable gives each row room.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Motion") {
                Toggle("Animate selection & navigation", isOn: bindable.animations)
                Text("Off: instant, no motion. Streaming row inserts never animate either way.")
                    .font(.caption).foregroundStyle(.secondary)
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

    private var tags: some View { TagManagerView(app: app) }

    private var plugins: some View {
        Form {
            Section("JavaScript plugins") {
                Text("Drop a .js file in the plugins folder to add columns, commands, and right-click actions. Plugins run in a JS sandbox: no network or process access — only the host API you approve below.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open Plugins Folder") { app.revealPluginsFolder() }
                    Button("Reload Plugins") { app.loadPlugins() }
                }
            }
            Section("Installed") {
                let plugins = app.availablePlugins()
                if plugins.isEmpty {
                    Text("No plugins installed.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(plugins, id: \.id) { p in
                    PluginRow(app: app, id: p.id, name: p.name, manifest: p.manifest, enabled: p.enabled)
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

// MARK: - Plugin row (Settings → Plugins, v0.8)

/// One installed plugin: enable toggle, manifest identity, capabilities, and a
/// trust badge. Enabling a plugin that wants a consent-requiring capability
/// (read:cwd) prompts first — the grant happens here in Settings, never from the
/// plugin. A bare `.js` (no manifest) shows as compute-only and can't be granted
/// anything beyond a column.
private struct PluginRow: View {
    let app: AppState
    let id: String
    let name: String
    let manifest: PluginManifest?
    let enabled: Bool

    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { on in
                        if on, needsConsent { confirming = true } else { app.setPlugin(id, enabled: on) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                        if let desc = manifest?.description {
                            Text(desc).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(manifest.map { "\($0.id) · \($0.version)" } ?? "compute-only (no manifest)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                trustBadge
            }
            if let caps = manifest?.capabilities, !caps.isEmpty {
                Text(caps.map(\.capabilityLabel).joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .alert("Enable \"\(name)\"?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Enable") { app.setPlugin(id, enabled: true) }
        } message: {
            Text(consentMessage)
        }
    }

    private var needsConsent: Bool {
        manifest?.capabilities.contains { $0.requiresConsent } ?? false
    }
    private var consentMessage: String {
        let caps = manifest?.capabilities.filter(\.requiresConsent) ?? []
        let lines = caps.map { "• " + $0.consentSummary }.joined(separator: "\n")
        return "Plugin id: \(id)\n\nThis plugin requests:\n\(lines)"
    }

    @ViewBuilder private var trustBadge: some View {
        let isBuiltIn = manifest?.author == "yafm"
        switch manifest?.trust ?? .unsigned {
        case .declaredAuthor:
            if isBuiltIn {
                Label("Built-in", systemImage: "checkmark.circle.fill").foregroundStyle(.blue)
            } else {
                Label(manifest?.author ?? "Author", systemImage: "person").foregroundStyle(.secondary)
            }
        case .unsigned:
            Label("Unsigned", systemImage: "exclamationmark.shield").foregroundStyle(.orange)
        }
    }
}

// MARK: - Tag manager (Settings → Tags)

/// A proper tag-management tool: every known tag with its color and file count,
/// each editable in place — recolor, rename across all files, or delete from all
/// files — plus the index rescan/clear controls.
struct TagManagerView: View {
    @Bindable var app: AppState

    private var tags: [Tag] {
        app.knownTags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("Manage tags") {
                if tags.isEmpty {
                    Text("No tags yet. Tag a file, or Rescan if you tagged files outside yafm.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(tags, id: \.name) { tag in row(tag) }
                }
            }
            Section("Tag index") {
                Text("The sidebar cloud and this list are built from an index of your files. Rescan after tagging outside yafm; clear to rebuild from scratch.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Rescan now") { app.rescanTags() }
                    Button("Clear index") { app.clearTags() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ tag: Tag) -> some View {
        HStack(spacing: 10) {
            colorMenu(tag)
            Text(tag.name).lineLimit(1)
            Spacer()
            Text("\(app.tagCounts[tag.name] ?? 0)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button { app.promptRenameTag(tag) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("Rename across all files")
            Button(role: .destructive) { app.promptDeleteTag(tag) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless).help("Remove from all files")
        }
    }

    /// A swatch that opens the 7 Finder colors + "No color"; picking recolors the
    /// tag on every file that carries it.
    private func colorMenu(_ tag: Tag) -> some View {
        Menu {
            Button("No color") { app.recolorTag(tag.name, colorIndex: nil) }
            ForEach(1..<Tag.colorNames.count, id: \.self) { i in
                Button {
                    app.recolorTag(tag.name, colorIndex: i)
                } label: {
                    Label(Tag.colorNames[i], systemImage: "circle.fill")
                }
            }
        } label: {
            Circle()
                .fill(Color.named(tag.colorName) ?? .secondary.opacity(0.4))
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.secondary.opacity(0.3)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
