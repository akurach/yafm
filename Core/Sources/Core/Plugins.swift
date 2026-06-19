import Foundation
import JavaScriptCore

// JavaScriptCore's execution-time-limit API lives in the private
// JSContextRefPrivate.h, which is absent from the public Swift module map — so we
// bind the stable exported symbol directly. This caps continuous JS execution so a
// runaway plugin (`while(true){}`) can't permanently freeze the app, which would
// break the product's defining "never freezes silently" guarantee. yafm is not
// sandboxed / App-Store-bound (see VISION), so using the private symbol is allowed.
private typealias JSShouldTerminateCallback =
    @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool

@_silgen_name("JSContextGroupSetExecutionTimeLimit")
private func JSContextGroupSetExecutionTimeLimit(
    _ group: JSContextGroupRef?, _ limit: Double,
    _ callback: JSShouldTerminateCallback?, _ context: UnsafeMutableRawPointer?)

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
///   table builds a row, so a runaway plugin can't corrupt state or escape the
///   snapshot it's handed. To stop a `while(true){}` from *permanently* freezing
///   the UI, every context's VM is capped via `JSContextGroupSetExecutionTimeLimit`
///   (`jsExecutionTimeLimitSeconds`): execution past the cap is aborted and the
///   call returns an empty cell, so the "never freezes silently" pillar holds even
///   for hostile plugin code.
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
    /// Contexts granted `read:exif` — get handles + `yafm.readEXIF`.
    private var readExifContexts: Set<ObjectIdentifier> = []
    /// Contexts granted `contribute:action` — get `openInApp`, `copyToClipboard`, `copyPath`.
    private var actionContexts: Set<ObjectIdentifier> = []
    /// Per-context handle → URL maps. Keyed by JSContext identity so one plugin
    /// can never forge or enumerate another plugin's handles (C-2 security fix).
    private var handleURLs: [ObjectIdentifier: [Int: URL]] = [:]
    private var handleByURL: [ObjectIdentifier: [URL: Int]] = [:]
    private var handleSeq = 0
    /// Per-context `readText` call budget — reset in `clearHandles()`.
    /// Keyed by context identity so one plugin can't exhaust another's budget.
    /// 500 calls × 256 KB = 128 MB max per plugin per session.
    private var readTextCallCounts: [ObjectIdentifier: Int] = [:]
    public static let readTextCallLimit = 500
    /// Cap a single capability read so a sync read of a 2 GB file can't freeze.
    public static let readTextCap = 256 * 1024   // 256 KB
    /// Wall-clock cap on a single uninterrupted JS call (column/command/menu).
    /// Past this the VM aborts the call (renders as an empty cell), so a runaway
    /// plugin can't permanently freeze the app. Generous enough that legitimate
    /// I/O-bound columns (EXIF/readText) finish; tight enough to bound an infinite
    /// loop to a recoverable hiccup rather than a dead window.
    public static let jsExecutionTimeLimitSeconds = 2.0

    // MARK: App-layer action handlers (set by AppState before loadPlugins)

    /// Opens a file URL in the app identified by the given bundle ID.
    public var openInAppHandler: ((URL, String) -> Void)?
    /// Writes a plain-text string to the system clipboard.
    public var copyToClipboardHandler: ((String) -> Void)?
    /// Resolves the handle's URL and writes the full path to the clipboard.
    public var copyPathHandler: ((URL) -> Void)?
    /// Returns EXIF/IPTC metadata as a JSON-serializable dict, or nil for non-images.
    public var readEXIFHandler: ((URL) -> [String: Any]?)?

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
      log: function () {},
      openInApp: function () {},
      copyToClipboard: function () {},
      copyPath: function () {},
      readEXIF: function () { return null; }
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
        readExifContexts.removeAll()
        actionContexts.removeAll()
        clearHandles()

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
        Self.capExecutionTime(of: context)   // bound runaway JS before any script runs
        var thrown: String?
        context.exceptionHandler = { _, value in
            thrown = value?.toString() ?? "unknown JS exception"
        }
        context.evaluateScript(Self.prelude)
        // Capability gates: inject bridges only for plugins whose manifest declares them.
        if manifest?.grants(.readCwd) == true {
            readCwdContexts.insert(ObjectIdentifier(context))
            injectReadText(into: context)
        }
        if manifest?.grants(.readExif) == true {
            readExifContexts.insert(ObjectIdentifier(context))
            injectReadEXIF(into: context)
        }
        if manifest?.grants(.action) == true {
            actionContexts.insert(ObjectIdentifier(context))
            injectActionBridges(into: context)
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
            // Read optional relevantExtensions array from the JS spec.
            var relevantExts: Set<String>? = nil
            if let jsArr = spec.objectForKeyedSubscript("relevantExtensions"),
               jsArr.isArray,
               let len = jsArr.objectForKeyedSubscript("length")?.toInt32(), len > 0 {
                var exts = Set<String>()
                for i in 0..<len {
                    if let ext = jsArr.objectAtIndexedSubscript(Int(i))?.toString() {
                        exts.insert(ext.lowercased())
                    }
                }
                if !exts.isEmpty { relevantExts = exts }
            }
            columns.append(PluginColumn(id: Self.columnIDPrefix + name + "." + rawID,
                                        title: title, relevantExtensions: relevantExts) {
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
                                                          handle: registerHandle(entry.url, in: context))])
    }

    /// Call a plugin column function with a read-only snapshot of the entry.
    /// Anything thrown by the plugin renders as an empty cell, never a crash.
    private func evaluate(_ fn: JSValue, for entry: FSEntry) -> ColumnValue {
        guard let context = fn.context else { return .none }
        let prior = context.exceptionHandler
        var thrown = false
        context.exceptionHandler = { _, _ in thrown = true }
        defer { context.exceptionHandler = prior }
        let oid = ObjectIdentifier(context)
        let needsHandle = readCwdContexts.contains(oid) || readExifContexts.contains(oid)
        let handle = needsHandle ? registerHandle(entry.url, in: context) : -1
        let snapshot = Self.snapshot(of: entry, in: context, handle: handle)
        guard let result = fn.call(withArguments: [snapshot]), !thrown else { return .none }
        if result.isNull || result.isUndefined { return .none }
        if result.isNumber { return .number(result.toDouble()) }
        return .text(result.toString() ?? "")
    }

    /// Cap continuous JS execution on `context`'s VM so a runaway plugin aborts
    /// instead of freezing the app. `JSContext()` makes a fresh VM (its own group)
    /// per context, so the limit is naturally scoped to this one plugin. A nil
    /// callback means JSC terminates execution at the limit (the call then throws,
    /// surfacing as an empty cell). See the `@_silgen_name` binding at file top.
    private static func capExecutionTime(of context: JSContext) {
        guard let global = context.jsGlobalContextRef else { return }
        JSContextGroupSetExecutionTimeLimit(
            JSContextGetGroup(global), jsExecutionTimeLimitSeconds, nil, nil)
    }

    /// Clear all handle maps and reset the readText call budget. Call on directory
    /// change or plugin reload so stale handles don't accumulate across sessions.
    public func clearHandles() {
        handleURLs.removeAll()
        handleByURL.removeAll()
        readTextCallCounts = [:]
    }

    /// Register a URL → opaque handle scoped to the given JSContext. A plugin can
    /// only resolve handles that were issued to *its own* context (C-2 fix).
    /// Per-context tables are evicted when they exceed 2000 entries to bound memory.
    private func registerHandle(_ url: URL, in context: JSContext) -> Int {
        let oid = ObjectIdentifier(context)
        if let existing = handleByURL[oid]?[url] { return existing }
        if (handleURLs[oid]?.count ?? 0) >= 2000 {
            handleURLs[oid] = nil
            handleByURL[oid] = nil
        }
        handleSeq += 1
        handleURLs[oid, default: [:]][handleSeq] = url
        handleByURL[oid, default: [:]][url] = handleSeq
        return handleSeq
    }

    /// Resolve a handle back to a URL, only within the calling context's scope.
    private func resolveHandle(_ handle: Int, in context: JSContext) -> URL? {
        handleURLs[ObjectIdentifier(context)]?[handle]
    }

    /// The vetted, path-free view of an entry a plugin receives.
    /// `path` is intentionally absent — use `yafm.copyPath(entry)` to write
    /// the full path to the clipboard (requires `contribute:action`).
    /// The optional `__h` is an opaque capability handle (scoped to this context).
    /// Widen the snapshot here, nowhere else.
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

    /// Install `yafm.openInApp`, `yafm.copyToClipboard`, `yafm.copyPath` into an action context.
    /// The handlers are resolved app-side (no AppKit import in Core) — Core only wires the bridge.
    private func injectActionBridges(into context: JSContext) {
        let openBridge: @convention(block) (JSValue?, JSValue?) -> Void = { [weak self] entryVal, bundleIdVal in
            MainActor.assumeIsolated {
                guard let self,
                      let callerCtx = entryVal?.context,
                      let handle = entryVal?.objectForKeyedSubscript("__h")?.toNumber()?.intValue,
                      handle >= 0,
                      let url = self.resolveHandle(handle, in: callerCtx),
                      let bundleId = bundleIdVal?.toString(), !bundleId.isEmpty,
                      let handler = self.openInAppHandler
                else { return }
                handler(url, bundleId)
            }
        }
        context.setObject(openBridge, forKeyedSubscript: "__yafm_openInApp" as NSString)

        let copyTextBridge: @convention(block) (JSValue?) -> Void = { [weak self] textVal in
            MainActor.assumeIsolated {
                guard let self,
                      let text = textVal?.toString(), !text.isEmpty,
                      text.count <= 1_000_000,
                      let handler = self.copyToClipboardHandler
                else { return }
                handler(text)
            }
        }
        context.setObject(copyTextBridge, forKeyedSubscript: "__yafm_copyToClipboard" as NSString)

        let copyPathBridge: @convention(block) (JSValue?) -> Void = { [weak self] entryVal in
            MainActor.assumeIsolated {
                guard let self,
                      let callerCtx = entryVal?.context,
                      let handle = entryVal?.objectForKeyedSubscript("__h")?.toNumber()?.intValue,
                      handle >= 0,
                      let url = self.resolveHandle(handle, in: callerCtx),
                      let handler = self.copyPathHandler
                else { return }
                handler(url)
            }
        }
        context.setObject(copyPathBridge, forKeyedSubscript: "__yafm_copyPath" as NSString)

        // Wrap natives in an IIFE and delete globals so plugins can't call
        // __yafm_* directly or access another plugin's bridge via global scope (P2-1).
        context.evaluateScript("""
        (function(_o, _c, _p) {
          yafm.openInApp      = function(e, b) { _o(e, b || ""); };
          yafm.copyToClipboard = function(t)   { _c(t || ""); };
          yafm.copyPath       = function(e)    { _p(e); };
        })(__yafm_openInApp, __yafm_copyToClipboard, __yafm_copyPath);
        delete globalThis.__yafm_openInApp;
        delete globalThis.__yafm_copyToClipboard;
        delete globalThis.__yafm_copyPath;
        """)
    }

    /// Install `yafm.readEXIF(entry)` into a `read:exif`-granted context.
    /// Returns JSON string (parsed in JS) to avoid capturing JSContext in the block.
    private func injectReadEXIF(into context: JSContext) {
        let bridge: @convention(block) (JSValue?) -> String? = { [weak self] entryVal in
            MainActor.assumeIsolated {
                guard let self,
                      let callerCtx = entryVal?.context,
                      let handle = entryVal?.objectForKeyedSubscript("__h")?.toNumber()?.intValue,
                      handle >= 0,
                      let url = self.resolveHandle(handle, in: callerCtx),
                      let handler = self.readEXIFHandler,
                      let dict = handler(url),
                      !dict.isEmpty,
                      let data = try? JSONSerialization.data(withJSONObject: dict),
                      let json = String(data: data, encoding: .utf8)
                else { return nil }
                return json
            }
        }
        context.setObject(bridge, forKeyedSubscript: "__yafm_readEXIF" as NSString)
        context.evaluateScript("""
        (function(_fn) {
          yafm.readEXIF = function(e) { var r = _fn(e); return r ? JSON.parse(r) : null; };
        })(__yafm_readEXIF);
        delete globalThis.__yafm_readEXIF;
        """)
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
                      let callerCtx = entryVal?.context,
                      let handle = entryVal?.objectForKeyedSubscript("__h")?.toNumber()?.intValue,
                      handle >= 0,
                      let base = self.resolveHandle(handle, in: callerCtx),
                      (self.readTextCallCounts[ObjectIdentifier(callerCtx)] ?? 0) < Self.readTextCallLimit
                else { return nil }
                self.readTextCallCounts[ObjectIdentifier(callerCtx), default: 0] += 1
                let rel = relVal?.toString() ?? ""
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir)
                let root = isDir.boolValue ? base : base.deletingLastPathComponent()
                let ctx = PluginContext(roots: [root])
                let candidatePath = rel.isEmpty ? root.path : root.appendingPathComponent(rel).path
                guard let target = ctx.resolve(candidatePath) else { return nil }
                return Self.readTextCapped(target)
            }
        }
        context.setObject(bridge, forKeyedSubscript: "__yafm_readText" as NSString)
        context.evaluateScript("""
        (function(_fn) {
          yafm.readText = function(entry, rel) { return _fn(entry, rel || ""); };
        })(__yafm_readText);
        delete globalThis.__yafm_readText;
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

    /// Reference plugin demonstrating `contribute:action`: context-menu items for
    /// popular apps + clipboard shortcuts. Seeded disabled (requires user grant).
    public static let openWithPlugin = """
    // yafm "Open With" plugin — context-menu shortcuts for popular apps.
    // Requires: contribute:menu + contribute:action  (see open-with.json)
    yafm.registerMenuItem({
      id: "open-vscode",
      title: "Open in VS Code",
      run: function(entry) { yafm.openInApp(entry, "com.microsoft.VSCode"); }
    });
    yafm.registerMenuItem({
      id: "open-iterm",
      title: "Open Folder in iTerm",
      run: function(entry) {
        if (entry.isDirectory) yafm.openInApp(entry, "com.googlecode.iterm2");
      }
    });
    yafm.registerMenuItem({
      id: "copy-path",
      title: "Copy Full Path",
      run: function(entry) { yafm.copyPath(entry); }
    });
    yafm.registerMenuItem({
      id: "copy-name",
      title: "Copy Name",
      run: function(entry) { yafm.copyToClipboard(entry.name); }
    });
    """

    public static let openWithManifest = """
    {
      "manifest": 1,
      "id": "com.yafm.open-with",
      "name": "Open With",
      "version": "1.0.0",
      "apiVersion": "1.0",
      "author": "yafm",
      "capabilities": ["contribute:menu", "contribute:action"],
      "contributes": {
        "menuItems": ["Open in VS Code", "Open Folder in iTerm", "Copy Full Path", "Copy Name"]
      }
    }
    """

    /// Reference plugin demonstrating `read:exif`: Camera and focal-length columns
    /// for raw/JPEG images. Seeded disabled (requires user grant of read:exif).
    public static let exifInfoPlugin = """
    // yafm EXIF Info plugin v1.2 — Camera and Focal/f columns for image files.
    // Requires: read:exif  (see exif-info.json)
    var _imgExts = [
      // JPEG
      "jpg","jpeg",
      // HEIF family (inc. Sony HIF, AVIF)
      "heic","heif","hif","avif",
      // TIFF
      "tiff","tif",
      // DNG (Adobe + many cameras)
      "dng",
      // Canon
      "cr2","cr3","crw",
      // Nikon
      "nef","nrw",
      // Sony
      "arw","srf","sr2",
      // Fuji
      "raf",
      // Olympus / OM System
      "orf",
      // Panasonic / Leica (shared format)
      "rw2","raw",
      // Pentax / Ricoh
      "pef","ptx",
      // Samsung
      "srw",
      // Hasselblad
      "3fr","fff",
      // Minolta / old Sony
      "mrw",
      // Sigma
      "x3f",
      // Epson
      "erf",
      // Kodak
      "kdc","dcr","k25",
      // Mamiya
      "mef",
      // Phase One
      "iiq",
      // Leica
      "rwl",
      // WebP
      "webp"
    ];
    yafm.registerColumn({
      id: "camera",
      title: "Camera",
      relevantExtensions: _imgExts,
      value: function(entry) {
        if (_imgExts.indexOf((entry.ext || "").toLowerCase()) < 0) return "";
        var m = yafm.readEXIF(entry);
        return m ? (m.model || m.make || "") : "";
      }
    });
    yafm.registerColumn({
      id: "focal",
      title: "Focal/f",
      relevantExtensions: _imgExts,
      value: function(entry) {
        if (_imgExts.indexOf((entry.ext || "").toLowerCase()) < 0) return "";
        var m = yafm.readEXIF(entry);
        if (!m) return "";
        var parts = [];
        if (m.focalLength) parts.push(m.focalLength + "mm");
        if (m.fNumber)     parts.push("f/" + m.fNumber);
        if (m.iso)         parts.push("ISO " + m.iso);
        return parts.join("  ");
      }
    });
    """

    public static let exifInfoManifest = """
    {
      "manifest": 1,
      "id": "com.yafm.exif-info",
      "name": "EXIF Info",
      "version": "1.2.0",
      "apiVersion": "1.0",
      "author": "yafm",
      "description": "Adds Camera and Focal/f columns read from EXIF. Works with JPEG, HEIF/HIF, AVIF, TIFF, WebP and all major RAW formats (DNG, CR2/CR3, ARW, NEF, RAF, ORF, RW2, PEF, SRW, 3FR, MRW, X3F…).",
      "capabilities": ["read:exif"],
      "contributes": { "columns": ["Camera", "Focal/f"] }
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
