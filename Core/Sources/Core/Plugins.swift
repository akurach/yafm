import Foundation
import JavaScriptCore

// MARK: - JavaScript plugin runtime (v0.3 Platform)

/// Hosts community plugins written in JavaScript, run through JavaScriptCore —
/// the Obsidian / Chrome model: drop a `.js` file in the plugins folder and it
/// works. Plugins can only do what this host exposes; there is **no** `require`,
/// no filesystem, no network, no `Process`. The single capability today is
/// `yafm.registerColumn`, which contributes a table column computed from a
/// read-only snapshot of each entry (name/ext/size/… — never a raw path).
///
/// Sandbox notes:
/// - Each plugin file gets its **own** `JSContext` (its own global scope), so one
///   plugin can't read or clobber another's globals.
/// - The host injects only a `yafm` object; the default JSC globals (`Math`,
///   `JSON`, `Date`, …) are pure-compute and safe. There is no DOM, no XHR, no
///   timers wired up, no module loader.
/// - A plugin column function is called synchronously on the main actor while the
///   table builds a row, so a runaway plugin slows the UI but can't corrupt state
///   or escape the snapshot it's handed.
///
/// This is the boundary `PluginContext` was drafted for: widening it (scoped FS
/// reads, a vetted git/exec capability) happens here, in one place, before any
/// new surface reaches untrusted JS.
@MainActor
public final class JSPluginHost {
    /// Metadata for a successfully loaded plugin file.
    public struct Loaded: Sendable {
        public let name: String
        public let columnTitles: [String]
    }

    /// A plugin file that failed to load, with the reason (surfaced in Settings).
    public struct LoadError: Sendable {
        public let name: String
        public let message: String
    }

    public private(set) var loaded: [Loaded] = []
    public private(set) var errors: [LoadError] = []

    /// Contexts are retained so the `JSValue` column functions stay alive.
    private var contexts: [JSContext] = []

    /// Id prefix for every JS-contributed column, so the registry can drop them
    /// on reload without touching native columns.
    public static let columnIDPrefix = "plugin.js."

    public init() {}

    /// The JS prelude run before each plugin: defines the `yafm` API surface.
    /// `registerColumn` just stashes specs into an array the host reads back —
    /// no Swift `@convention(block)` callbacks, so nothing non-Sendable crosses
    /// the boundary. `log` is a no-op sink (kept so plugins can call it safely).
    private static let prelude = """
    var yafm = {
      __columns: [],
      version: "0.3",
      registerColumn: function (spec) {
        if (!spec || typeof spec.value !== "function") {
          throw new Error("registerColumn needs { id, title, value: function(entry) }");
        }
        this.__columns.push(spec);
      },
      log: function () {}
    };
    """

    /// Load every `*.js` file in `directory` (non-recursive). Missing dir = no-op.
    /// Returns the `PluginColumn`s contributed, ready to hand to the registry.
    @discardableResult
    public func loadPlugins(from directory: URL) -> [PluginColumn] {
        loaded.removeAll()
        errors.removeAll()
        contexts.removeAll()

        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var columns: [PluginColumn] = []
        for file in names.sorted() where file.hasSuffix(".js") {
            let url = directory.appendingPathComponent(file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                errors.append(LoadError(name: file, message: "unreadable file"))
                continue
            }
            columns.append(contentsOf: load(source: source, name: file))
        }
        return columns
    }

    /// Evaluate one plugin's source in a fresh context and harvest its columns.
    /// Exposed for tests; production goes through `loadPlugins(from:)`.
    @discardableResult
    public func load(source: String, name: String) -> [PluginColumn] {
        guard let context = JSContext() else {
            errors.append(LoadError(name: name, message: "could not create JS context"))
            return []
        }
        var thrown: String?
        context.exceptionHandler = { _, value in
            thrown = value?.toString() ?? "unknown JS exception"
        }
        context.evaluateScript(Self.prelude)
        context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: name))
        if let thrown {
            errors.append(LoadError(name: name, message: thrown))
            return []
        }

        guard let specs = context.objectForKeyedSubscript("yafm")?
            .objectForKeyedSubscript("__columns"),
            let count = specs.objectForKeyedSubscript("length")?.toNumber()?.intValue
        else {
            errors.append(LoadError(name: name, message: "plugin did not register anything"))
            return []
        }

        contexts.append(context)   // retain so the JSValue functions stay valid
        var columns: [PluginColumn] = []
        var titles: [String] = []
        for i in 0..<count {
            guard let spec = specs.objectAtIndexedSubscript(i),
                  let fn = spec.objectForKeyedSubscript("value"), fn.isObject
            else { continue }
            let rawID = spec.objectForKeyedSubscript("id")?.toString() ?? "col\(i)"
            let title = spec.objectForKeyedSubscript("title")?.toString() ?? rawID
            let id = Self.columnIDPrefix + name + "." + rawID
            titles.append(title)
            columns.append(PluginColumn(id: id, title: title) { [weak self] entry in
                self?.evaluate(fn, for: entry) ?? .none
            })
        }
        loaded.append(Loaded(name: name, columnTitles: titles))
        return columns
    }

    /// Call a plugin column function with a read-only snapshot of the entry.
    /// Anything thrown by the plugin renders as an empty cell, never a crash.
    private func evaluate(_ fn: JSValue, for entry: FSEntry) -> ColumnValue {
        guard let context = fn.context else { return .none }
        var thrown = false
        context.exceptionHandler = { _, _ in thrown = true }
        let snapshot = Self.snapshot(of: entry, in: context)
        guard let result = fn.call(withArguments: [snapshot]), !thrown else { return .none }
        if result.isNull || result.isUndefined { return .none }
        if result.isNumber { return .number(result.toDouble()) }
        return .text(result.toString() ?? "")
    }

    /// The vetted, path-free view of an entry a plugin column receives.
    /// Deliberately excludes `url`/absolute path so JS can't exfiltrate or act on
    /// locations; widening this is the one place to do it.
    private static func snapshot(of entry: FSEntry, in context: JSContext) -> JSValue {
        var dict: [String: Any] = [
            "name": entry.name,
            "ext": entry.url.pathExtension,
            "isDirectory": entry.isDirectory,
            "isHidden": entry.isHidden,
            "tags": entry.tags.map(\.name),
        ]
        if let size = entry.size { dict["size"] = size }
        if let modified = entry.modified { dict["modified"] = modified.timeIntervalSince1970 * 1000 }
        return JSValue(object: dict, in: context) ?? JSValue(undefinedIn: context)
    }

    /// A complete, editable example plugin, seeded into an empty plugins folder
    /// on first run: a "Type" column that classifies each entry by extension.
    /// Demonstrates the whole `yafm.registerColumn` round-trip end to end.
    public static let exampleColumnPlugin = """
    // yafm example plugin — adds a "Type" column.
    // Edit me, or drop your own *.js here. The host calls value(entry) per row
    // with a read-only snapshot: { name, ext, isDirectory, isHidden, size, modified, tags }
    yafm.registerColumn({
      id: "type",
      title: "Type",
      value: function (entry) {
        if (entry.isDirectory) return "📁 Folder";
        var images = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff"];
        var code   = ["swift", "js", "ts", "py", "rs", "go", "c", "h", "cpp", "java", "rb"];
        var docs   = ["pdf", "md", "txt", "rtf", "doc", "docx", "pages"];
        var av     = ["mp3", "wav", "aac", "flac", "mp4", "mov", "m4v", "avi"];
        var ext = (entry.ext || "").toLowerCase();
        if (images.indexOf(ext) >= 0) return "🖼 Image";
        if (code.indexOf(ext) >= 0)   return "⚙︎ Code";
        if (docs.indexOf(ext) >= 0)   return "📄 Document";
        if (av.indexOf(ext) >= 0)     return "🎬 Media";
        return ext ? ext.toUpperCase() : "File";
      }
    });
    """

    /// Default on-disk plugins folder: `~/Library/Application Support/yafm/plugins`.
    public static func defaultPluginsDirectory() -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let plugins = dir.appendingPathComponent("yafm/plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        return plugins
    }
}
