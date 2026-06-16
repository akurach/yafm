import SwiftUI
import AppKit
import Observation
import Core
import PhosphorSwift

// MARK: - Persisted app settings (v0.2.3 app shell)

/// Accent colour palette. `system` defers to macOS System Preferences.
enum AppAccent: String, CaseIterable, Identifiable {
    case system, blue, purple, pink, red, orange, yellow, green, teal, graphite
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var color: Color? {
        switch self {
        case .system:   return nil
        case .blue:     return Color(red: 0.20, green: 0.47, blue: 0.95)
        case .purple:   return Color(red: 0.59, green: 0.33, blue: 0.90)
        case .pink:     return Color(red: 0.95, green: 0.28, blue: 0.56)
        case .red:      return Color(red: 0.92, green: 0.24, blue: 0.24)
        case .orange:   return Color(red: 0.98, green: 0.54, blue: 0.12)
        case .yellow:   return Color(red: 0.85, green: 0.68, blue: 0.10)
        case .green:    return Color(red: 0.18, green: 0.72, blue: 0.40)
        case .teal:     return Color(red: 0.10, green: 0.65, blue: 0.75)
        case .graphite: return Color(red: 0.50, green: 0.50, blue: 0.52)
        }
    }
}

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

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light:  NSAppearance(named: .aqua)
        case .dark:   NSAppearance(named: .darkAqua)
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
        case .compact:              IBMPlex.mono(12)
        case .cozy, .comfortable:  IBMPlex.mono(13)
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

/// Standard system folders that appear in the Sidebar Favorites section.
/// Order here is the display order.
enum SystemFavorite: String, CaseIterable, Identifiable, Hashable {
    case desktop, documents, downloads, movies, music, pictures, applications
    var id: String { rawValue }
    var label: String {
        switch self {
        case .applications: "Applications"
        default: rawValue.capitalized
        }
    }
    var systemImage: String {
        switch self {
        case .desktop:      "display"
        case .documents:    "doc"
        case .downloads:    "arrow.down.to.line.compact"
        case .movies:       "play.circle"
        case .music:        "music.note"
        case .pictures:     "photo"
        case .applications: "square.grid.2x2"
        }
    }
    static let defaults: Set<SystemFavorite> = [.desktop, .documents, .downloads, .applications]
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

    /// → (right arrow) on an app/package: enter its contents as a folder (on, the
    /// default) or launch the app (off). Double-click always launches.
    var rightArrowEntersPackages: Bool { didSet { store.set(rightArrowEntersPackages, forKey: Keys.rightArrowEntersPackages) } }

    /// Light / Dark / System.
    var theme: AppTheme {
        didSet {
            store.set(theme.rawValue, forKey: Keys.theme)
            // Defer to the next runloop tick — mutating NSApp.appearance inside an
            // @Observable didSet during a SwiftUI update can re-enter the layout pass.
            let appearance = theme.nsAppearance
            DispatchQueue.main.async { NSApp.appearance = appearance }
        }
    }

    /// Single mechanism for applying the window appearance (`NSApp.appearance`).
    /// Called at launch (`AppState.start`); the `theme` didSet mirrors it for live
    /// changes (must hop to main async from the observation callback).
    @MainActor func applyTheme() { NSApp.appearance = theme.nsAppearance }

    /// Row density (Compact / Cozy / Comfortable).
    var density: Density { didSet { store.set(density.rawValue, forKey: Keys.density) } }

    /// Draw colored file-type tiles (extension chips) for known types instead of
    /// the system icon. Off → every file uses its real macOS icon.
    var filetypeTiles: Bool { didSet { store.set(filetypeTiles, forKey: Keys.filetypeTiles) } }

    /// User-defined extension → tile overrides, stored as `"categoryRaw|LABEL"`.
    /// Checked before the built-in catalog, so users can add or recolor types.
    var customFileTypes: [String: String] { didSet { store.set(customFileTypes, forKey: Keys.customFileTypes) } }

    /// Per-category color overrides, stored as `"r,g,b"` (0–1 sRGB). The resolved
    /// color is the single source of truth for BOTH the tile and (optionally) the
    /// filename tint, so they can never disagree.
    var categoryColors: [String: String] { didSet { store.set(categoryColors, forKey: Keys.categoryColors) } }

    /// Tint the filename with its type color (same color as the tile). Off → the
    /// name uses the normal text color; the tile alone carries the type color.
    var tintNamesByType: Bool { didSet { store.set(tintNamesByType, forKey: Keys.tintNamesByType) } }

    /// Drag-to-reorder state for the sidebar. `favoritesOrder` is item ids
    /// (`"sys:downloads"` / `"bm:<uuid>"`); `sidebarSectionOrder` is section keys.
    /// Empty/missing entries fall back to the natural order and are appended.
    var favoritesOrder: [String] { didSet { store.set(favoritesOrder, forKey: Keys.favoritesOrder) } }
    var sidebarSectionOrder: [String] { didSet { store.set(sidebarSectionOrder, forKey: Keys.sidebarSectionOrder) } }

    /// Collapsed sidebar sections (by section key). Collapsed = only the header
    /// shows; tapping the header toggles it.
    var collapsedSidebarSections: Set<String> {
        didSet { store.set(Array(collapsedSidebarSections), forKey: Keys.collapsedSidebarSections) }
    }

    func toggleSectionCollapsed(_ key: String) {
        if collapsedSidebarSections.contains(key) { collapsedSidebarSections.remove(key) }
        else { collapsedSidebarSections.insert(key) }
    }

    /// Move `dragged` to where `target` currently sits within an ordered id list.
    static func reordered(_ list: [String], moving dragged: String, before target: String) -> [String] {
        guard dragged != target, let from = list.firstIndex(of: dragged) else { return list }
        var arr = list
        arr.remove(at: from)
        let to = arr.firstIndex(of: target) ?? arr.count
        arr.insert(dragged, at: to)
        return arr
    }

    /// Resolved sRGB for a category: user override → built-in default.
    func rgb(for category: FileTypeCategory) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        if let raw = categoryColors[category.rawValue] {
            let c = raw.split(separator: ",").compactMap { Double($0) }
            if c.count == 3 { return (CGFloat(c[0]), CGFloat(c[1]), CGFloat(c[2])) }
        }
        return category.rgb
    }

    func color(for category: FileTypeCategory) -> Color {
        let c = rgb(for: category); return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// Persist a category color from a SwiftUI `Color` (resets to default if nil-ish).
    func setColor(_ color: Color, for category: FileTypeCategory) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        categoryColors[category.rawValue] = "\(ns.redComponent),\(ns.greenComponent),\(ns.blueComponent)"
    }

    func resetColor(for category: FileTypeCategory) { categoryColors[category.rawValue] = nil }

    /// Resolved tile for an entry: (sRGB, label) or nil for folders/unknown/off.
    func tileTint(for entry: FSEntry) -> (rgb: (r: CGFloat, g: CGFloat, b: CGFloat), label: String)? {
        guard let (cat, label) = tile(for: entry) else { return nil }
        return (rgb(for: cat), label)
    }

    /// Resolve (category, label) for an extension: user override → built-in catalog
    /// → nil. Ignores the `filetypeTiles` toggle (used by both the tile and the
    /// name-tint paths, which gate on the toggle themselves).
    func typeMapping(forExtension ext: String) -> (category: FileTypeCategory, label: String)? {
        let key = ext.lowercased()
        if let raw = customFileTypes[key] {
            let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
            if let first = parts.first, let cat = FileTypeCategory(rawValue: first) {
                return (cat, parts.count > 1 ? parts[1] : key.uppercased())
            }
        }
        return FileTypeCatalog.entry(forExtension: key)
    }

    /// Resolve the tile for a file extension, honoring the tiles toggle.
    func tile(forExtension ext: String) -> (category: FileTypeCategory, label: String)? {
        filetypeTiles ? typeMapping(forExtension: ext) : nil
    }

    /// Tile for an entry (folders always use the system icon → nil).
    func tile(for entry: FSEntry) -> (category: FileTypeCategory, label: String)? {
        entry.isDirectory ? nil : tile(forExtension: entry.url.pathExtension)
    }

    /// File-table column visibility (Name is always shown). Hiding columns also
    /// keeps the row from overflowing a narrow pane.
    var showSizeColumn: Bool     { didSet { store.set(showSizeColumn, forKey: Keys.showSizeColumn) } }
    var showModifiedColumn: Bool { didSet { store.set(showModifiedColumn, forKey: Keys.showModifiedColumn) } }
    var showKindColumn: Bool     { didSet { store.set(showKindColumn, forKey: Keys.showKindColumn) } }
    var showGitColumn: Bool      { didSet { store.set(showGitColumn, forKey: Keys.showGitColumn) } }

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

    /// App accent colour (nil = follow macOS System Preferences).
    var accent: AppAccent { didSet { store.set(accent.rawValue, forKey: Keys.accent) } }

    // Sidebar section visibility
    var sidebarShowFavorites:   Bool { didSet { store.set(sidebarShowFavorites,   forKey: Keys.sidebarShowFavorites) } }
    var sidebarShowLocations:   Bool { didSet { store.set(sidebarShowLocations,   forKey: Keys.sidebarShowLocations) } }
    var sidebarShowICloud:      Bool { didSet { store.set(sidebarShowICloud,      forKey: Keys.sidebarShowICloud) } }
    var sidebarShowDevices:     Bool { didSet { store.set(sidebarShowDevices,     forKey: Keys.sidebarShowDevices) } }
    var sidebarShowNetwork:     Bool { didSet { store.set(sidebarShowNetwork,     forKey: Keys.sidebarShowNetwork) } }
    var sidebarShowTags:        Bool { didSet { store.set(sidebarShowTags,        forKey: Keys.sidebarShowTags) } }

    /// Which standard system folders appear in the Sidebar Favorites section.
    var enabledFavorites: Set<SystemFavorite> {
        didSet {
            store.set(enabledFavorites.map(\.rawValue), forKey: Keys.enabledFavorites)
        }
    }

    // Locations items visibility
    var locShowComputer: Bool { didSet { store.set(locShowComputer, forKey: Keys.locShowComputer) } }
    var locShowHome:     Bool { didSet { store.set(locShowHome,     forKey: Keys.locShowHome) } }

    /// Last 5 server addresses successfully attempted via Connect to Server (⌘⇧K).
    var recentServers: [String] { didSet { store.set(recentServers, forKey: Keys.recentServers) } }

    @ObservationIgnored private let store = UserDefaults.standard

    private enum Keys {
        static let rightArrowOpensFiles = "rightArrowOpensFiles"
        static let showHiddenByDefault = "showHiddenByDefault"
        static let rightArrowEntersPackages = "rightArrowEntersPackages"
        static let theme = "theme"
        static let density = "density"
        static let filetypeTiles = "filetypeTiles"
        static let showSizeColumn = "showSizeColumn"
        static let showModifiedColumn = "showModifiedColumn"
        static let showKindColumn = "showKindColumn"
        static let showGitColumn = "showGitColumn"
        static let customFileTypes = "customFileTypes"
        static let categoryColors = "categoryColors"
        static let tintNamesByType = "tintNamesByType"
        static let favoritesOrder = "favoritesOrder"
        static let sidebarSectionOrder = "sidebarSectionOrder"
        static let collapsedSidebarSections = "collapsedSidebarSections"
        static let language = "language"
        static let animations = "animations"
        static let startMode = "startMode"
        static let customStartPath = "customStartPath"
        static let lastFolder = "lastFolder"
        static let confirmBeforeDelete = "confirmBeforeDelete"
        static let collisionDefault = "collisionDefault"
        static let sidebarShowFavorites = "sidebarShowFavorites"
        static let sidebarShowLocations = "sidebarShowLocations"
        static let sidebarShowICloud    = "sidebarShowICloud"
        static let sidebarShowDevices   = "sidebarShowDevices"
        static let sidebarShowNetwork   = "sidebarShowNetwork"
        static let sidebarShowTags      = "sidebarShowTags"
        static let enabledFavorites = "enabledFavorites"
        static let locShowComputer = "locShowComputer"
        static let locShowHome     = "locShowHome"
        static let recentServers   = "recentServers"
        static let accent          = "accent"
    }

    init() {
        let d = UserDefaults.standard
        rightArrowOpensFiles = d.bool(forKey: Keys.rightArrowOpensFiles)   // default false → folders only
        showHiddenByDefault = d.bool(forKey: Keys.showHiddenByDefault)
        rightArrowEntersPackages = d.object(forKey: Keys.rightArrowEntersPackages) as? Bool ?? true
        theme = AppTheme(rawValue: d.string(forKey: Keys.theme) ?? "") ?? .system
        density = Density(rawValue: d.string(forKey: Keys.density) ?? "") ?? .cozy
        filetypeTiles = d.object(forKey: Keys.filetypeTiles) as? Bool ?? true   // default on
        showSizeColumn     = d.object(forKey: Keys.showSizeColumn)     as? Bool ?? true
        showModifiedColumn = d.object(forKey: Keys.showModifiedColumn) as? Bool ?? true
        showKindColumn     = d.object(forKey: Keys.showKindColumn)     as? Bool ?? true
        showGitColumn      = d.object(forKey: Keys.showGitColumn)      as? Bool ?? true
        customFileTypes    = d.dictionary(forKey: Keys.customFileTypes) as? [String: String] ?? [:]
        categoryColors     = d.dictionary(forKey: Keys.categoryColors) as? [String: String] ?? [:]
        tintNamesByType    = d.object(forKey: Keys.tintNamesByType) as? Bool ?? false
        favoritesOrder     = d.stringArray(forKey: Keys.favoritesOrder) ?? []
        sidebarSectionOrder = d.stringArray(forKey: Keys.sidebarSectionOrder) ?? []
        collapsedSidebarSections = Set(d.stringArray(forKey: Keys.collapsedSidebarSections) ?? [])

        language = AppLanguage(rawValue: d.string(forKey: Keys.language) ?? "") ?? .system
        animations = d.object(forKey: Keys.animations) as? Bool ?? true   // default on
        startMode = StartMode(rawValue: d.string(forKey: Keys.startMode) ?? "") ?? .home
        customStartPath = d.string(forKey: Keys.customStartPath) ?? ""
        // Permanent delete: confirm by default unless the user has explicitly set it.
        confirmBeforeDelete = d.object(forKey: Keys.confirmBeforeDelete) as? Bool ?? true
        collisionDefault = CollisionPolicy(rawValue: d.string(forKey: Keys.collisionDefault) ?? "") ?? .keepBoth
        accent = AppAccent(rawValue: d.string(forKey: Keys.accent) ?? "") ?? .system
        sidebarShowFavorites = d.object(forKey: Keys.sidebarShowFavorites) as? Bool ?? true
        sidebarShowLocations = d.object(forKey: Keys.sidebarShowLocations) as? Bool ?? true
        sidebarShowICloud    = d.object(forKey: Keys.sidebarShowICloud)    as? Bool ?? true
        sidebarShowDevices   = d.object(forKey: Keys.sidebarShowDevices)   as? Bool ?? true
        sidebarShowNetwork   = d.object(forKey: Keys.sidebarShowNetwork)   as? Bool ?? true
        sidebarShowTags      = d.object(forKey: Keys.sidebarShowTags)      as? Bool ?? true
        if let rawValues = d.array(forKey: Keys.enabledFavorites) as? [String] {
            enabledFavorites = Set(rawValues.compactMap(SystemFavorite.init(rawValue:)))
        } else {
            enabledFavorites = SystemFavorite.defaults
        }
        locShowComputer = d.object(forKey: Keys.locShowComputer) as? Bool ?? true
        locShowHome     = d.object(forKey: Keys.locShowHome)     as? Bool ?? true
        recentServers   = d.array(forKey: Keys.recentServers)    as? [String] ?? []
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

    private var checkTask: Task<Void, Never>?

    func check() {
        checkTask?.cancel()
        status = .checking
        checkTask = Task {
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

/// Settings tabs (drives the Mole-style pill switcher).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, operations, sidebar, tags, plugins, updates
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general:    return "General"
        case .appearance: return "Appearance"
        case .operations: return "Operations"
        case .sidebar:    return "Sidebar"
        case .tags:       return "Tags"
        case .plugins:    return "Plugins"
        case .updates:    return "Updates"
        }
    }
    var icon: Image {
        switch self {
        case .general:    return Ph.gearSix.regular
        case .appearance: return Ph.paintBrush.regular
        case .operations: return Ph.arrowsLeftRight.regular
        case .sidebar:    return Ph.sidebarSimple.regular
        case .tags:       return Ph.tag.regular
        case .plugins:    return Ph.puzzlePiece.regular
        case .updates:    return Ph.arrowCircleDown.regular
        }
    }
}

struct SettingsView: View {
    @Bindable var app: AppState
    @State private var updates = UpdateChecker()
    @State private var tab: SettingsTab = .general
    var onClose: () -> Void = {}

    private var settings: AppSettings { app.settings }

    var body: some View {
        VStack(spacing: 0) {
            header
            SettingsTabBar(selection: $tab)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 660, height: 580)
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(IBMPlex.sans(22, weight: .semibold))
            Spacer()
            Button(action: onClose) {
                Ph.x.bold
                    .renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 12)
                    .foregroundStyle(.secondary)
                    .padding(7)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .general:    general
        case .appearance: appearance
        case .operations: operations
        case .sidebar:    sidebarTab
        case .tags:       tags
        case .plugins:    plugins
        case .updates:    updatesTab
        }
    }

    private var general: some View {
        sScroll {
            SettingsGroup("THEME") {
                SettingsRow("Appearance") {
                    Picker("", selection: bindable.theme) {
                        ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
            }
            SettingsGroup("DENSITY",
                          footer: "Compact packs more rows on screen; Comfortable gives each row room.") {
                SettingsRow("Row density") {
                    Picker("", selection: bindable.density) {
                        ForEach(Density.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
            }
            SettingsGroup("MOTION",
                          footer: "Off: instant, no motion. Streaming row inserts never animate either way.") {
                SettingsRow("Animate selection & navigation") {
                    Toggle("", isOn: bindable.animations).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsGroup("START FOLDER") {
                SettingsRow("New windows open at") {
                    Picker("", selection: bindable.startMode) {
                        ForEach(StartMode.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 140)
                }
                if settings.startMode == .custom {
                    SettingsDivider()
                    SettingsRow("Folder") {
                        HStack(spacing: 6) {
                            Text(settings.customStartPath.isEmpty ? "None" : settings.customStartPath)
                                .font(IBMPlex.mono(11)).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                            Button("Choose…") { chooseStartFolder() }.controlSize(.small)
                        }
                    }
                }
            }
            SettingsGroup("NAVIGATION",
                          footer: "Off: → only enters folders. On: → also opens files. Enter always opens. For apps, → either browses the bundle contents or launches the app.") {
                SettingsRow("Right arrow opens files") {
                    Toggle("", isOn: bindable.rightArrowOpensFiles).labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("Right arrow on apps") {
                    Picker("", selection: bindable.rightArrowEntersPackages) {
                        Text("Show contents").tag(true)
                        Text("Launch app").tag(false)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
            }
            SettingsGroup("LISTING") {
                SettingsRow("Show hidden files in new tabs") {
                    Toggle("", isOn: bindable.showHiddenByDefault).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsGroup("LANGUAGE", footer: "Takes effect after you quit and reopen yafm.") {
                SettingsRow("Language") {
                    Picker("", selection: bindable.language) {
                        ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 120)
                }
            }
            SettingsGroup("FULL DISK ACCESS",
                          footer: "Lets yafm read protected folders (Desktop, Documents, others apps' data). Grant it in System Settings, then re-check. Always reachable here even after dismissing the banner.") {
                SettingsRow("Status") {
                    HStack(spacing: 6) {
                        Image(systemName: app.hasFullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(app.hasFullDiskAccess ? .green : .orange)
                        Text(app.hasFullDiskAccess ? "Enabled" : "Not granted")
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsDivider()
                SettingsRow("Access") {
                    HStack(spacing: 8) {
                        Button("Open System Settings…") { app.openFullDiskAccessSettings() }
                        Button("Re-check") { app.checkAccess() }.controlSize(.small)
                    }
                }
            }
        }
    }

    private var appearance: some View {
        sScroll {
            SettingsGroup("ACCENT COLOR",
                          footer: "System follows macOS System Preferences → General → Accent color.") {
                SettingsRow("Accent color") {
                    HStack(spacing: 8) {
                        ForEach(AppAccent.allCases) { a in
                            AccentSwatch(accent: a, isSelected: settings.accent == a) {
                                settings.accent = a
                            }
                        }
                    }
                }
            }
            // File-type tiles: switches, then the one type→color palette (used by
            // both the tile and the name tint), then a browser of every known type.
            // (Column show/hide is NOT here — it's on the table's own header.)
            SettingsGroup("FILE-TYPE TILES",
                          footer: "Colored extension chips for known types. Off: every file uses its real macOS icon; folders always do.") {
                SettingsRow("Colored type tiles") {
                    Toggle("", isOn: bindable.filetypeTiles).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow("Tint file names by type") {
                    Toggle("", isOn: bindable.tintNamesByType).labelsHidden().toggleStyle(.switch)
                }
            }
            if settings.filetypeTiles || settings.tintNamesByType {
                SettingsGroup("TYPE COLORS",
                              footer: "One palette drives both the tile and the name tint, so they always match. Click a swatch to recolor; ↺ resets.") {
                    CategoryColorsEditor(settings: settings)
                }
                SettingsGroup("FILE TYPES",
                              footer: "Every known extension and its category. Search to check what's mapped; pick a different category to override, or add your own.") {
                    TypeBrowser(settings: settings)
                }
            }
        }
    }

    private var operations: some View {
        sScroll {
            SettingsGroup("DELETE",
                          footer: "Delete is permanent (not Trash). Keep this on unless you're sure.") {
                SettingsRow("Confirm before deleting") {
                    Toggle("", isOn: bindable.confirmBeforeDelete).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsGroup("COPY / MOVE COLLISIONS") {
                SettingsRow("When a file already exists") {
                    Picker("", selection: bindable.collisionDefault) {
                        Text("Keep both").tag(CollisionPolicy.keepBoth)
                        Text("Skip").tag(CollisionPolicy.skip)
                        Text("Replace").tag(CollisionPolicy.replace)
                    }.labelsHidden().frame(width: 120)
                }
            }
        }
    }

    private var sidebarTab: some View {
        sScroll {
            SettingsGroup("SECTIONS") {
                SettingsRow("Favorites")  { Toggle("", isOn: bindable.sidebarShowFavorites).labelsHidden().toggleStyle(.switch) }
                SettingsDivider()
                SettingsRow("Locations")  { Toggle("", isOn: bindable.sidebarShowLocations).labelsHidden().toggleStyle(.switch) }
                SettingsDivider()
                SettingsRow("Devices")    { Toggle("", isOn: bindable.sidebarShowDevices).labelsHidden().toggleStyle(.switch) }
                SettingsDivider()
                SettingsRow("Network")    { Toggle("", isOn: bindable.sidebarShowNetwork).labelsHidden().toggleStyle(.switch) }
                SettingsDivider()
                SettingsRow("Tags")       { Toggle("", isOn: bindable.sidebarShowTags).labelsHidden().toggleStyle(.switch) }
            }
            SettingsGroup("FAVORITES") {
                ForEach(Array(SystemFavorite.allCases.enumerated()), id: \.1.id) { i, fav in
                    if i > 0 { SettingsDivider() }
                    SettingsRow(fav.label) { Toggle("", isOn: favBinding(fav)).labelsHidden().toggleStyle(.switch) }
                }
                SettingsDivider()
                if app.bookmarks.isEmpty {
                    HStack {
                        Text("No custom folders yet.").font(IBMPlex.sans(12)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12).frame(minHeight: 34)
                } else {
                    ForEach(app.bookmarks) { bm in
                        SettingsDivider()
                        SettingsRow(bm.name) {
                            Button { app.removeBookmark(bm) } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                SettingsDivider()
                Button { chooseFavorite() } label: {
                    HStack {
                        Image(systemName: "plus.circle").foregroundStyle(Color.accentColor)
                        Text("Add Folder…").font(IBMPlex.sans(13)).foregroundStyle(Color.accentColor)
                        Spacer()
                    }
                    .padding(.horizontal, 12).frame(minHeight: 38)
                }
                .buttonStyle(.plain)
            }
            .disabled(!settings.sidebarShowFavorites)
            SettingsGroup("LOCATIONS") {
                SettingsRow("Computer")    { Toggle("", isOn: bindable.locShowComputer).labelsHidden().toggleStyle(.switch) }
                SettingsDivider()
                SettingsRow("Home")        { Toggle("", isOn: bindable.locShowHome).labelsHidden().toggleStyle(.switch) }
                SettingsDivider()
                SettingsRow("iCloud Drive") { Toggle("", isOn: bindable.sidebarShowICloud).labelsHidden().toggleStyle(.switch) }
            }
            .disabled(!settings.sidebarShowLocations)
        }
    }

    private func favBinding(_ fav: SystemFavorite) -> Binding<Bool> {
        Binding(
            get: { settings.enabledFavorites.contains(fav) },
            set: { on in
                var s = settings.enabledFavorites
                if on { s.insert(fav) } else { s.remove(fav) }
                settings.enabledFavorites = s
            }
        )
    }

    @MainActor private func chooseFavorite() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add to Favorites"
        panel.message = "Choose a folder to add to Favorites in the sidebar."
        if panel.runModal() == .OK, let url = panel.url {
            app.addBookmark(url)
        }
    }

    private var tags: some View { TagManagerView(app: app) }

    private var plugins: some View {
        sScroll {
            SettingsGroup("JAVASCRIPT PLUGINS",
                          footer: "Drop a .js file in the plugins folder to add columns, commands, and right-click actions. Plugins run sandboxed: no network or process access.") {
                SettingsRow("Plugins folder") {
                    HStack(spacing: 6) {
                        Button("Open") { app.revealPluginsFolder() }.controlSize(.small)
                        Button("Reload") { app.loadPlugins() }.controlSize(.small)
                    }
                }
            }
            let available = app.availablePlugins()
            SettingsGroup("INSTALLED") {
                if available.isEmpty {
                    HStack {
                        Text("No plugins installed.").font(IBMPlex.sans(12)).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(.horizontal, 12).frame(minHeight: 38)
                } else {
                    ForEach(Array(available.enumerated()), id: \.1.id) { i, p in
                        if i > 0 { SettingsDivider() }
                        PluginRow(app: app, id: p.id, name: p.name, manifest: p.manifest, enabled: p.enabled)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                }
            }
            if !app.pluginHost.loaded.isEmpty || !app.pluginHost.errors.isEmpty {
                SettingsGroup("LOADED") {
                    ForEach(Array(app.pluginHost.loaded.enumerated()), id: \.1.name) { i, p in
                        if i > 0 { SettingsDivider() }
                        HStack {
                            Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.secondary)
                            Text(p.name).font(IBMPlex.sans(13))
                            Spacer()
                            Text(p.columnTitles.joined(separator: ", "))
                                .font(IBMPlex.sans(11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, 12).frame(minHeight: 38)
                    }
                    ForEach(app.pluginHost.errors, id: \.name) { e in
                        SettingsDivider()
                        HStack {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                            Text("\(e.name): \(e.message)").font(IBMPlex.sans(12)).foregroundStyle(.red).lineLimit(2)
                        }.padding(.horizontal, 12).frame(minHeight: 38)
                    }
                }
            }
        }
    }

    private var updatesTab: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return sScroll {
            SettingsGroup("UPDATES", footer: "Current version: \(version).") {
                SettingsRow("Check for updates") {
                    HStack(spacing: 8) {
                        statusView
                        Button("Check") { updates.check() }.controlSize(.small)
                    }
                }
            }
        }
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

    @MainActor private func chooseStartFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { settings.customStartPath = url.path }
    }
}

// MARK: - In-window Settings overlay (Mole-style)

/// Dimmed backdrop + floating settings card, presented inside the main window so
/// it can never be dragged outside the app. Click-outside or ✕ / Esc dismisses.
struct SettingsOverlay: View {
    @Bindable var app: AppState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if app.showSettings {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .transition(.opacity)

                SettingsView(app: app, onClose: close)
                    .background(Theme.Palette.panesSurface(scheme == .dark))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.primary.opacity(scheme == .dark ? 0.16 : 0.10), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(scheme == .dark ? 0.55 : 0.28), radius: 40, y: 18)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: app.showSettings)
    }

    private func close() { app.showSettings = false }
}

/// Pill-style tab switcher (Mole-style): a capsule track with one filled pill for
/// the active tab; the fill glides between pills.
struct SettingsTabBar: View {
    @Binding var selection: SettingsTab
    @Environment(\.colorScheme) private var scheme
    @Namespace private var pill

    private var selectedFill: Color {
        // Same neutral gamut as the chrome/panel surfaces, just darker than the
        // track — a grey "selected" chip, never harsh black.
        scheme == .dark ? Color(white: 0.30) : Color(white: 0.62)
    }
    private var selectedText: Color {
        scheme == .dark ? Color.white : Color(white: 0.12)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { t in
                let active = t == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { selection = t }
                } label: {
                    HStack(spacing: 5) {
                        t.icon
                            .renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 13, height: 13)
                        Text(t.label).font(IBMPlex.sans(12, weight: active ? .semibold : .regular))
                    }
                    // Inverted selected pill (Mole-style): dark chip on light theme,
                    // light chip on dark theme — text flips to stay legible.
                    .foregroundStyle(active ? selectedText : Color.secondary)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 11)
                    .background {
                        if active {
                            Capsule(style: .continuous)
                                .fill(selectedFill)
                                .matchedGeometryEffect(id: "pill", in: pill)
                                .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.20), radius: 3, y: 1)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(scheme == .dark ? 0.07 : 0.05)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Settings layout helpers

private extension SettingsView {
    func sScroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsGroup<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let header: String
    var footer: String? = nil
    let content: Content

    init(_ header: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    private var fillColor: Color  { scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04) }
    private var strokeColor: Color { scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(header)
                .font(IBMPlex.sans(10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .padding(.leading, 2)
            VStack(spacing: 0) {
                content
            }
            .background(fillColor)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(strokeColor, lineWidth: 0.5)
            }
            if let footer {
                Text(footer)
                    .font(IBMPlex.sans(11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsRow<C: View>: View {
    let label: String
    let control: C

    init(_ label: String, @ViewBuilder control: () -> C) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(IBMPlex.sans(13))
            Spacer()
            control
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
    }
}

struct SettingsDivider: View {
    var body: some View { Divider().padding(.leading, 12) }
}

// MARK: - Accent color swatch

private struct AccentSwatch: View {
    let accent: AppAccent
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(swatchColor)
                    .frame(width: 20, height: 20)
                if isSelected {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.6), lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .help(accent.label)
    }

    private var swatchColor: Color {
        if let c = accent.color { return c }
        // "System" swatch: macOS default blue
        return Color(red: 0.20, green: 0.47, blue: 0.95)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsGroup("MANAGE TAGS") {
                    if tags.isEmpty {
                        HStack {
                            Text("No tags yet. Tag a file, or Rescan if you tagged files outside yafm.")
                                .font(IBMPlex.sans(12)).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12).frame(minHeight: 38)
                    } else {
                        ForEach(Array(tags.enumerated()), id: \.1.name) { i, tag in
                            if i > 0 { SettingsDivider() }
                            row(tag)
                        }
                    }
                }
                SettingsGroup("TAG INDEX",
                              footer: "The sidebar cloud and this list are built from an index of your files. Rescan after tagging outside yafm; clear to rebuild from scratch.") {
                    SettingsRow("Index") {
                        HStack(spacing: 8) {
                            Button("Rescan now") { app.rescanTags() }.controlSize(.small)
                            Button("Clear index") { app.clearTags() }.controlSize(.small)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ tag: Tag) -> some View {
        HStack(spacing: 10) {
            colorMenu(tag)
            Text(tag.name).font(IBMPlex.sans(13)).lineLimit(1)
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
        .padding(.horizontal, 12).frame(minHeight: 38)
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

// MARK: - File-type tile editors (Settings ▸ Appearance)

/// One row per category: a live tile sample + name + color well + reset. The
/// color is the single source for the tile and the (optional) name tint.
struct CategoryColorsEditor: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(FileTypeCategory.allCases) { cat in
                HStack(spacing: 8) {
                    FileTypeTile(rgb: settings.rgb(for: cat),
                                 label: FileTypeCatalog.extensions(in: cat).first?.uppercased() ?? "?",
                                 size: 16)
                    Text(cat.displayName).font(.system(size: 12))
                    Spacer()
                    if settings.categoryColors[cat.rawValue] != nil {
                        Button { settings.resetColor(for: cat) } label: {
                            Image(systemName: "arrow.uturn.backward").font(.system(size: 10))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Reset \(cat.displayName) color")
                    }
                    ColorPicker("", selection: Binding(
                        get: { settings.color(for: cat) },
                        set: { settings.setColor($0, for: cat) }
                    )).labelsHidden().frame(width: 44)
                }
            }
        }
    }
}

/// Browsable list of every known extension with its category, searchable, with a
/// per-row category override and an add-your-own row. Lets users see exactly what
/// is mapped (e.g. is `py` or `vcf` here?) and change it.
struct TypeBrowser: View {
    @Bindable var settings: AppSettings
    @State private var query = ""
    @State private var newExt = ""
    @State private var newCat: FileTypeCategory = .code

    private struct Row: Identifiable { let ext: String; let cat: FileTypeCategory; let label: String; let custom: Bool; var id: String { ext } }

    private var rows: [Row] {
        var seen = Set<String>()
        var out: [Row] = []
        for (ext, raw) in settings.customFileTypes {
            let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
            if let first = parts.first, let cat = FileTypeCategory(rawValue: first) {
                out.append(Row(ext: ext, cat: cat, label: parts.count > 1 ? parts[1] : ext.uppercased(), custom: true))
                seen.insert(ext)
            }
        }
        for (ext, v) in FileTypeCatalog.map where !seen.contains(ext) {
            out.append(Row(ext: ext, cat: v.category, label: v.label, custom: false))
        }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
        return out.filter { q.isEmpty || $0.ext.contains(q) }.sorted { $0.ext < $1.ext }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search extension — e.g. py, vcf, braw…", text: $query)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in
                        HStack(spacing: 8) {
                            FileTypeTile(rgb: settings.rgb(for: row.cat), label: row.label, size: 16)
                            Text(".\(row.ext)").font(.system(size: 12, design: .monospaced))
                            if row.custom {
                                Text("custom").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Picker("", selection: Binding(
                                get: { row.cat },
                                set: { settings.customFileTypes[row.ext] = "\($0.rawValue)|\(row.label)" }
                            )) {
                                ForEach(FileTypeCategory.allCases) { Text($0.displayName).tag($0) }
                            }.labelsHidden().frame(width: 150)
                            if row.custom {
                                Button { settings.customFileTypes[row.ext] = nil } label: {
                                    Image(systemName: "arrow.uturn.backward").font(.system(size: 10))
                                }.buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("Reset .\(row.ext)")
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            .frame(height: 220)
            Divider()
            HStack(spacing: 6) {
                TextField("add ext", text: $newExt).frame(width: 70).textFieldStyle(.roundedBorder)
                Picker("", selection: $newCat) {
                    ForEach(FileTypeCategory.allCases) { Text($0.displayName).tag($0) }
                }.labelsHidden().frame(width: 150)
                Button("Add") {
                    let e = newExt.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ".", with: "")
                    guard !e.isEmpty else { return }
                    settings.customFileTypes[e] = "\(newCat.rawValue)|\(e.uppercased())"
                    newExt = ""; query = e
                }.disabled(newExt.trimmingCharacters(in: .whitespaces).isEmpty)
            }.font(.system(size: 12))
        }
    }
}
