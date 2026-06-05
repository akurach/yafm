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
        /// Manifest, when a sidecar `<plugin>.json` was present and valid.
        public let manifest: PluginManifest?
        public let commandTitles: [String]
        public let menuTitles: [String]
        public init(name: String, columnTitles: [String], manifest: PluginManifest? = nil,
                    commandTitles: [String] = [], menuTitles: [String] = []) {
            self.name = name
            self.columnTitles = columnTitles
            self.manifest = manifest
            self.commandTitles = commandTitles
            self.menuTitles = menuTitles
        }
    }

    /// A JS-contributed command/menu item: a stable id, a title, and the JS
    /// function the host calls when it runs. The `JSValue` is retained via its
    /// context (kept in `contexts`).
    public struct JSAction {
        public let id: String
        public let title: String
        let fn: JSValue
    }

    public private(set) var commands: [JSAction] = []
    public private(set) var menuItems: [JSAction] = []

    /// Ids (manifest id, else file name) the user disabled in Settings. Disabled
    /// plugins are skipped entirely on load.
    public var disabledIDs: Set<String> = []

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
    public static let commandIDPrefix = "plugin.cmd."
    public static let menuIDPrefix = "plugin.menu."

    /// Contexts whose plugin was granted `read:cwd` — only these get a real
    /// snapshot handle + the `yafm.readText` bridge.
    private var readCwdContexts: Set<ObjectIdentifier> = []
    /// Opaque handle → real URL map. JS receives the integer handle, never the
    /// path, and `readText` resolves host-side (scoped, O_NOFOLLOW, size-capped).
    private var handleURLs: [Int: URL] = [:]
    private var handleSeq = 0
    /// Cap a single capability read so a sync read of a 2 GB file can't freeze.
    public static let readTextCap = 256 * 1024   // 256 KB

    public init() {}

    /// The JS prelude run before each plugin: defines the `yafm` API surface.
    /// `registerColumn` just stashes specs into an array the host reads back —
    /// no Swift `@convention(block)` callbacks, so nothing non-Sendable crosses
    /// the boundary. `log` is a no-op sink (kept so plugins can call it safely).
    private static let prelude = """
    var yafm = {
      __columns: [],
      __commands: [],
      __menu: [],
      version: "\(PluginAPI.currentVersion)",
      registerColumn: function (spec) {
        if (!spec || typeof spec.value !== "function") {
          throw new Error("registerColumn needs { id, title, value: function(entry) }");
        }
        this.__columns.push(spec);
      },
      registerCommand: function (spec) {
        if (!spec || typeof spec.run !== "function") {
          throw new Error("registerCommand needs { id, title, run: function() }");
        }
        this.__commands.push(spec);
      },
      registerMenuItem: function (spec) {
        if (!spec || typeof spec.run !== "function") {
          throw new Error("registerMenuItem needs { id, title, run: function(entry) }");
        }
        this.__menu.push(spec);
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
        commands.removeAll()
        menuItems.removeAll()
        readCwdContexts.removeAll()
        handleURLs.removeAll()
        handleByURL.removeAll()

        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var columns: [PluginColumn] = []
        for file in names.sorted() where file.hasSuffix(".js") {
            let url = directory.appendingPathComponent(file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                errors.append(LoadError(name: file, message: "unreadable file"))
                continue
            }
            // Optional sidecar manifest: `<base>.json`. Absent → compute-only.
            // Present-but-invalid → surface the error and skip (don't silently
            // downgrade a plugin that declared capabilities).
            let manifestURL = url.deletingPathExtension().appendingPathExtension("json")
            var manifest: PluginManifest?
            if let data = try? Data(contentsOf: manifestURL) {
                do { manifest = try PluginManifest.parse(data) }
                catch {
                    let why = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    errors.append(LoadError(name: file, message: why))
                    continue
                }
            }
            let id = manifest?.id ?? file
            if disabledIDs.contains(id) { continue }   // user-disabled in Settings
            columns.append(contentsOf: load(source: source, name: file, manifest: manifest))
        }
        return columns
    }

    /// Discover the plugins present (for Settings ▸ Plugins), independent of
    /// enable state — so a disabled plugin still appears with its toggle. Returns
    /// `(id, displayName, manifest?)` for every `.js`.
    public func discoverPlugins(in directory: URL) -> [(id: String, name: String, manifest: PluginManifest?)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [(String, String, PluginManifest?)] = []
        for file in names.sorted() where file.hasSuffix(".js") {
            let manifestURL = directory.appendingPathComponent(file)
                .deletingPathExtension().appendingPathExtension("json")
            let manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? PluginManifest.parse($0) }
            out.append((manifest?.id ?? file, manifest?.name ?? file, manifest))
        }
        return out
    }

    /// Evaluate one plugin's source in a fresh context and harvest its columns.
    /// Exposed for tests; production goes through `loadPlugins(from:)`.
    @discardableResult
    public func load(source: String, name: String, manifest: PluginManifest? = nil) -> [PluginColumn] {
        guard let context = JSContext() else {
            errors.append(LoadError(name: name, message: "could not create JS context"))
            return []
        }
        var thrown: String?
        context.exceptionHandler = { _, value in
            thrown = value?.toString() ?? "unknown JS exception"
        }
        context.evaluateScript(Self.prelude)
        // Capability gate: only a plugin whose manifest grants read:cwd gets the
        // host-resolved readText bridge. Everyone else has no FS reach at all.
        if manifest?.grants(.readCwd) == true {
            readCwdContexts.insert(ObjectIdentifier(context))
            injectReadText(into: context)
        }
        context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: name))
        if let thrown {
            errors.append(LoadError(name: name, message: thrown))
            return []
        }
        contexts.append(context)   // retain so the JSValue functions stay valid

        let api = context.objectForKeyedSubscript("yafm")
        var columns: [PluginColumn] = []
        var colTitles: [String] = []
        var cmdTitles: [String] = []
        var menuTitles: [String] = []

        // Columns (always allowed — snapshot-only compute).
        for spec in specs(api, "__columns") {
            guard let fn = spec.objectForKeyedSubscript("value"), fn.isObject else { continue }
            let rawID = spec.objectForKeyedSubscript("id")?.toString() ?? "col\(columns.count)"
            let title = spec.objectForKeyedSubscript("title")?.toString() ?? rawID
            colTitles.append(title)
            columns.append(PluginColumn(id: Self.columnIDPrefix + name + "." + rawID, title: title) {
                [weak self] entry in self?.evaluate(fn, for: entry) ?? .none
            })
        }

        // Commands + menu items — only when the manifest grants the capability.
        if manifest?.grants(.command) == true {
            for spec in specs(api, "__commands") {
                guard let fn = spec.objectForKeyedSubscript("run"), fn.isObject else { continue }
                let rawID = spec.objectForKeyedSubscript("id")?.toString() ?? "cmd\(commands.count)"
                let title = spec.objectForKeyedSubscript("title")?.toString() ?? rawID
                commands.append(JSAction(id: Self.commandIDPrefix + name + "." + rawID, title: title, fn: fn))
                cmdTitles.append(title)
            }
        }
        if manifest?.grants(.contextMenu) == true {
            for spec in specs(api, "__menu") {
                guard let fn = spec.objectForKeyedSubscript("run"), fn.isObject else { continue }
                let rawID = spec.objectForKeyedSubscript("id")?.toString() ?? "menu\(menuItems.count)"
                let title = spec.objectForKeyedSubscript("title")?.toString() ?? rawID
                menuItems.append(JSAction(id: Self.menuIDPrefix + name + "." + rawID, title: title, fn: fn))
                menuTitles.append(title)
            }
        }

        guard !columns.isEmpty || !cmdTitles.isEmpty || !menuTitles.isEmpty else {
            errors.append(LoadError(name: name, message: "plugin did not register anything"))
            return []
        }
        loaded.append(Loaded(name: name, columnTitles: colTitles, manifest: manifest,
                             commandTitles: cmdTitles, menuTitles: menuTitles))
        return columns
    }

    /// Read back a registered-spec array from the `yafm` API object.
    private func specs(_ api: JSValue?, _ key: String) -> [JSValue] {
        guard let arr = api?.objectForKeyedSubscript(key),
              let count = arr.objectForKeyedSubscript("length")?.toNumber()?.intValue else { return [] }
        return (0..<count).compactMap { arr.objectAtIndexedSubscript($0) }
    }

    /// Run a JS command by id (from the palette / menus). Exceptions are swallowed.
    public func runCommand(_ id: String) {
        guard let action = commands.first(where: { $0.id == id }), let ctx = action.fn.context else { return }
        let prior = ctx.exceptionHandler
        ctx.exceptionHandler = { _, _ in }
        defer { ctx.exceptionHandler = prior }   // restore so column eval still reports (P2-3)
        _ = action.fn.call(withArguments: [])
    }

    /// Run a JS context-menu item against an entry.
    public func runMenuItem(_ id: String, on entry: FSEntry) {
        guard let action = menuItems.first(where: { $0.id == id }),
              let context = action.fn.context else { return }
        let prior = context.exceptionHandler
        context.exceptionHandler = { _, _ in }
        defer { context.exceptionHandler = prior }
        _ = action.fn.call(withArguments: [Self.snapshot(of: entry, in: context,
                                                          handle: registerHandle(entry.url))])
    }

    /// Call a plugin column function with a read-only snapshot of the entry.
    /// Anything thrown by the plugin renders as an empty cell, never a crash.
    private func evaluate(_ fn: JSValue, for entry: FSEntry) -> ColumnValue {
        guard let context = fn.context else { return .none }
        var thrown = false
        context.exceptionHandler = { _, _ in thrown = true }
        // Only readCwd-granted plugins get a usable handle (others get -1).
        let handle = readCwdContexts.contains(ObjectIdentifier(context)) ? registerHandle(entry.url) : -1
        let snapshot = Self.snapshot(of: entry, in: context, handle: handle)
        guard let result = fn.call(withArguments: [snapshot]), !thrown else { return .none }
        if result.isNull || result.isUndefined { return .none }
        if result.isNumber { return .number(result.toDouble()) }
        return .text(result.toString() ?? "")
    }

    /// Map a URL to an opaque handle the JS side passes back to `readText`.
    /// Deduped by URL so the map is bounded by unique files seen, not by render
    /// count — the old per-evaluate insert grew without bound (perf/security).
    private var handleByURL: [URL: Int] = [:]
    private func registerHandle(_ url: URL) -> Int {
        if let existing = handleByURL[url] { return existing }
        handleSeq += 1
        handleURLs[handleSeq] = url
        handleByURL[url] = handleSeq
        return handleSeq
    }

    /// The vetted, path-free view of an entry a plugin receives. Excludes
    /// `url`/absolute path; the optional `__h` is the opaque capability handle
    /// (only non-negative for read:cwd plugins). Widen here, nowhere else.
    private static func snapshot(of entry: FSEntry, in context: JSContext, handle: Int = -1) -> JSValue {
        var dict: [String: Any] = [
            "name": entry.name,
            "ext": entry.url.pathExtension,
            "isDirectory": entry.isDirectory,
            "isHidden": entry.isHidden,
            "tags": entry.tags.map(\.name),
            "__h": handle,
        ]
        if let size = entry.size { dict["size"] = size }
        if let modified = entry.modified { dict["modified"] = modified.timeIntervalSince1970 * 1000 }
        return JSValue(object: dict, in: context) ?? JSValue(undefinedIn: context)
    }

    /// Install `yafm.readText(entry, rel)` into a granted context. The bridge
    /// reads the entry's opaque handle, resolves `rel` host-side against the
    /// entry's directory (the `read:cwd` scope) via `PluginContext` — refusing
    /// any `..`/symlink escape — opens with `O_NOFOLLOW`, and returns at most
    /// `readTextCap` bytes. Returns `null` on any denial so JS can't tell a
    /// permission failure from a missing file.
    private func injectReadText(into context: JSContext) {
        let bridge: @convention(block) (JSValue?, JSValue?) -> String? = { [weak self] entryVal, relVal in
            MainActor.assumeIsolated {
                guard let self,
                      let handle = entryVal?.objectForKeyedSubscript("__h")?.toNumber()?.intValue,
                      let base = self.handleURLs[handle] else { return nil }
                let rel = relVal?.toString() ?? ""
                // The scope root is the entry itself when it's a directory, else
                // its containing folder. Check the filesystem, not the URL's
                // directory hint (entries aren't built with one).
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir)
                let root = isDir.boolValue ? base : base.deletingLastPathComponent()
                let ctx = PluginContext(roots: [root])
                let candidatePath = rel.isEmpty ? root.path : root.appendingPathComponent(rel).path
                guard let target = ctx.resolve(candidatePath) else { return nil }
                return Self.readTextCapped(target)   // nil → JS null
            }
        }
        context.setObject(bridge, forKeyedSubscript: "__yafm_readText" as NSString)
        context.evaluateScript("""
        yafm.readText = function (entry, rel) { return __yafm_readText(entry, rel || ""); };
        """)
    }

    /// Open with `O_NOFOLLOW` (TOCTOU/symlink-safe) and read up to the cap.
    private static func readTextCapped(_ url: URL) -> String? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < readTextCap {
            let n = read(fd, &buffer, min(buffer.count, readTextCap - data.count))
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return String(decoding: data, as: UTF8.self)
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

    /// Flagship capability plugin (v0.8): a "Branch" column that reads a folder's
    /// `.git/HEAD` through the granted `read:cwd` capability — proof the scoped-FS
    /// path works end to end, and a partial stand-in for the native `Git.swift`.
    public static let gitBranchPlugin = """
    // yafm git-branch plugin — shows the current branch for a Git repo folder.
    // Uses the read:cwd capability (granted in Settings) via yafm.readText, which
    // resolves host-side against the folder, refusing any path escape.
    yafm.registerColumn({
      id: "branch",
      title: "Branch",
      value: function (entry) {
        if (!entry.isDirectory) return "";
        var head = yafm.readText(entry, ".git/HEAD");
        if (!head) return "";
        var m = head.match(/ref:\\s*refs\\/heads\\/(.+)/);
        return m ? "\\u238E " + m[1].trim() : "\\u238E detached";
      }
    });
    yafm.registerCommand({
      id: "about",
      title: "About the Git Branch plugin",
      run: function () { yafm.log("git-branch: reads .git/HEAD via read:cwd"); }
    });
    """

    /// Sidecar manifest for the git-branch plugin (declares `read:cwd`).
    public static let gitBranchManifest = """
    {
      "manifest": 1,
      "id": "com.yafm.git-branch",
      "name": "Git Branch",
      "version": "1.0.0",
      "apiVersion": "1.0",
      "author": "yafm",
      "capabilities": ["read:cwd", "contribute:command"],
      "contributes": { "columns": ["Branch"], "commands": ["About the Git Branch plugin"] }
    }
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
