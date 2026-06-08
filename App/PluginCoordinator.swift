import Foundation
import AppKit
import ImageIO
import Core

// MARK: - Plugin domain extracted from AppState (A-3)

@MainActor
@Observable
final class PluginCoordinator {
    let registry = ExtensionRegistry()
    let pluginHost = JSPluginHost()
    let pluginValueCache = PluginValueCache()
    var pluginValuesVersion = 0
    var disabledPluginIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "disabledPlugins") ?? [])

    // Extensions that may execute code — shared by openFile (AppState), editCursor,
    // and the plugin openInApp handler so the gate can never drift between call sites.
    static let riskyExtensions: Set<String> = [
        "sh", "command", "zsh", "bash",
        "scpt", "applescript", "workflow",
        "app", "term", "tool", "action",
        "pkg", "mpkg",
    ]

    func loadPlugins() {
        guard let dir = JSPluginHost.defaultPluginsDirectory() else { return }
        installBundledPluginsIfNeeded(into: dir)

        pluginHost.openInAppHandler = { url, bundleId in
            // C-1: executable files require explicit user confirmation.
            if Self.riskyExtensions.contains(url.pathExtension.lowercased()) {
                let alert = NSAlert()
                alert.messageText = "Open potentially unsafe file?"
                alert.informativeText = "\"\(url.lastPathComponent)\" may run code on your Mac. A plugin requested this action."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Open Anyway")
                alert.alertStyle = .warning
                guard alert.runModal() == .alertSecondButtonReturn else { return }
            }
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
            NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                    configuration: .init(), completionHandler: nil)
        }
        pluginHost.copyToClipboardHandler = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        pluginHost.copyPathHandler = { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
        pluginHost.readEXIFHandler = Self.readEXIF(from:)

        registry.removePluginColumns(idPrefix: JSPluginHost.columnIDPrefix)
        pluginValueCache.invalidate()
        pluginHost.disabledIDs = disabledPluginIDs
        for column in pluginHost.loadPlugins(from: dir) {
            registry.register(pluginColumn: column)
        }
    }

    func availablePlugins() -> [(id: String, name: String, manifest: PluginManifest?, enabled: Bool)] {
        guard let dir = JSPluginHost.defaultPluginsDirectory() else { return [] }
        return pluginHost.discoverPlugins(in: dir).map {
            ($0.id, $0.name, $0.manifest, !disabledPluginIDs.contains($0.id))
        }
    }

    func setPlugin(_ id: String, enabled: Bool) {
        if enabled { disabledPluginIDs.remove(id) } else { disabledPluginIDs.insert(id) }
        UserDefaults.standard.set(Array(disabledPluginIDs), forKey: "disabledPlugins")
        loadPlugins()
    }

    func revealPluginsFolder() {
        guard let dir = JSPluginHost.defaultPluginsDirectory() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    func pluginCommands() -> [(id: String, title: String)] {
        pluginHost.commands.map { ($0.id, $0.title) }
    }

    func pluginMenuItems() -> [(id: String, title: String)] {
        pluginHost.menuItems.map { ($0.id, $0.title) }
    }

    func runPluginMenuItem(_ id: String, on entry: FSEntry) {
        pluginHost.runMenuItem(id, on: entry)
    }

    // MARK: Private

    private func installBundledPluginsIfNeeded(into dir: URL) {
        func path(_ name: String) -> URL { dir.appendingPathComponent(name) }
        func missing(_ name: String) -> Bool { !FileManager.default.fileExists(atPath: path(name).path) }
        func write(_ content: String, to name: String) {
            do { try content.write(to: path(name), atomically: true, encoding: .utf8) }
            catch { print("[yafm] installBundledPlugins: failed to write \(name): \(error)") }
        }
        func stale(_ name: String, expected: String) -> Bool {
            (try? String(contentsOf: path(name), encoding: .utf8)) != expected
        }
        let installed = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if !installed.contains(where: { $0.hasSuffix(".js") }) {
            write(JSPluginHost.exampleColumnPlugin, to: "example-kind.js")
        }
        if missing("git-branch.js") {
            write(JSPluginHost.gitBranchPlugin,   to: "git-branch.js")
            write(JSPluginHost.gitBranchManifest, to: "git-branch.json")
            disabledPluginIDs.insert("com.yafm.git-branch")
        } else if stale("git-branch.js", expected: JSPluginHost.gitBranchPlugin) {
            write(JSPluginHost.gitBranchPlugin,   to: "git-branch.js")
        }
        if missing("open-with.js") {
            write(JSPluginHost.openWithPlugin,    to: "open-with.js")
            write(JSPluginHost.openWithManifest,  to: "open-with.json")
            disabledPluginIDs.insert("com.yafm.open-with")
        } else if stale("open-with.js", expected: JSPluginHost.openWithPlugin) {
            write(JSPluginHost.openWithPlugin,    to: "open-with.js")
        }
        if missing("exif-info.js") {
            write(JSPluginHost.exifInfoPlugin,    to: "exif-info.js")
            write(JSPluginHost.exifInfoManifest,  to: "exif-info.json")
            disabledPluginIDs.insert("com.yafm.exif-info")
        } else if stale("exif-info.js", expected: JSPluginHost.exifInfoPlugin) {
            write(JSPluginHost.exifInfoPlugin,    to: "exif-info.js")
        }
        UserDefaults.standard.set(Array(disabledPluginIDs), forKey: "disabledPlugins")
    }

    private static func readEXIF(from url: URL) -> [String: Any]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
                  ?? CGImageSourceCopyProperties(src, nil)) as? [String: Any]
        guard let props else { return nil }

        var result: [String: Any] = [:]
        if let w = props[kCGImagePropertyPixelWidth as String]  { result["width"]  = w }
        if let h = props[kCGImagePropertyPixelHeight as String] { result["height"] = h }

        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let d   = exif[kCGImagePropertyExifDateTimeOriginal as String] { result["dateOriginal"] = d }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first { result["iso"] = iso }
            if let f   = exif[kCGImagePropertyExifFocalLength as String]    { result["focalLength"] = f }
            if let fn  = exif[kCGImagePropertyExifFNumber as String]        { result["fNumber"] = fn }
            if let exp = exif[kCGImagePropertyExifExposureTime as String]   { result["exposureTime"] = exp }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            if let make  = tiff[kCGImagePropertyTIFFMake as String]  as? String { result["make"]  = make }
            if let model = tiff[kCGImagePropertyTIFFModel as String] as? String { result["model"] = model }
        }
        // GPS excluded: a plugin with read:exif+contribute:action could silently
        // copy location data. A future read:exif:gps capability will gate this.
        return result.isEmpty ? nil : result
    }
}
