import Foundation

// MARK: - Native macOS tags (Finder-compatible) + index

/// Reads/writes native Finder tags via the extended attribute
/// `com.apple.metadata:_kMDItemUserTags` (a binary-plist array of strings,
/// each `"Name"` or `"Name\n<colorIndex>"`), and keeps an index so
/// "show everything tagged X" is instant.
public protocol TagServing: Sendable {
    func tags(of url: URL) async -> [Tag]
    func setTags(_ tags: [Tag], on url: URL) async throws
    func allKnownTags() async -> [Tag]
    func entries(taggedWith tag: Tag) async -> [URL]
    /// Background-populate the index by walking the given roots, so the tag
    /// cloud isn't empty before the user has browsed anywhere.
    func index(roots: [URL]) async
    /// Forget a URL after it was moved/renamed/deleted, so the cloud counts and
    /// "everything tagged X" listings don't reference a path that's gone.
    func forget(_ url: URL) async
    /// Load / save the on-disk index so a cold start doesn't full-rescan Home.
    func loadPersisted() async
    func persist() async
}

public actor TagService: TagServing {
    private static let attr = "com.apple.metadata:_kMDItemUserTags"

    /// tag name -> color (last writer wins) and -> set of URLs.
    private var colors: [String: Int?] = [:]
    private var index: [String: Set<URL>] = [:]
    /// Reverse map url -> its tag names, so dropping stale memberships on
    /// reindex is O(tags-on-this-url) instead of O(all tags) (was P1: O(N·T)).
    private var urlTags: [URL: Set<String>] = [:]

    /// Where the persisted index lives (Application Support/yafm/tag-index.json).
    private let storeURL: URL?

    public init(storeURL: URL? = TagService.defaultStoreURL()) {
        self.storeURL = storeURL
    }

    public func tags(of url: URL) async -> [Tag] {
        let tags = Self.readTags(url)
        reindex(url, tags)
        return tags
    }

    public func setTags(_ tags: [Tag], on url: URL) async throws {
        try Self.writeTags(tags, url)
        reindex(url, tags)
    }

    public func allKnownTags() async -> [Tag] {
        colors.map { Tag(name: $0.key, colorIndex: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func entries(taggedWith tag: Tag) async -> [URL] {
        Array(index[tag.name] ?? [])
    }

    /// Populate the index with everything tagged under `roots`, via Spotlight.
    ///
    /// We ask `mdfind` for files carrying `kMDItemUserTags` instead of walking the
    /// tree ourselves: a manual walk with `.skipsHiddenFiles` misses tags living
    /// under `~/Library` (e.g. iCloud Drive at `~/Library/Mobile Documents`),
    /// which is exactly where most tagged files end up. Spotlight sees them and
    /// is near-instant. Reads run in a background task; results merge in one hop.
    public func index(roots: [URL]) async {
        let collected: [(URL, [Tag])] = await Task.detached(priority: .background) {
            let fm = FileManager.default
            let limit = 50_000
            var seen = Set<URL>()
            var out: [(URL, [Tag])] = []

            // Returns false to stop the whole walk (cancelled or hit the cap).
            func consider(_ url: URL) -> Bool {
                if Task.isCancelled || out.count >= limit { return false }
                guard seen.insert(url).inserted else { return true }
                let tags = Self.readTags(url)
                if !tags.isEmpty { out.append((url, tags)) }
                return true
            }

            // Spotlight across the whole system (no -onlyin): every file the user
            // has tagged, wherever it lives — Home, iCloud (~/Library/Mobile
            // Documents), external disks. A hidden-skipping walk misses most of these.
            for url in Self.spotlightTaggedPaths(in: nil) where !consider(url) { return out }

            // Direct walk of the explicit roots too, for places Spotlight hasn't
            // indexed yet (a freshly mounted card, temp dirs).
            for root in roots {
                if let en = fm.enumerator(
                    at: root, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    while let url = en.nextObject() as? URL, consider(url) {}
                    if Task.isCancelled || out.count >= limit { return out }
                }
            }
            return out
        }.value

        for (url, tags) in collected { reindex(url, tags) }
    }

    /// Paths carrying any native tag, via `mdfind`. `root == nil` searches the
    /// whole Spotlight index (all of the user's tagged files); otherwise scopes
    /// to `root`.
    private static func spotlightTaggedPaths(in root: URL?) -> [URL] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        proc.arguments = root.map { ["-onlyin", $0.path, "kMDItemUserTags == '*'"] }
            ?? ["kMDItemUserTags == '*'"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
    }

    public func forget(_ url: URL) {
        for name in urlTags[url] ?? [] { index[name]?.remove(url) }
        urlTags[url] = nil
    }

    private func reindex(_ url: URL, _ tags: [Tag]) {
        // Drop only the memberships this url actually had, via the reverse map.
        for name in urlTags[url] ?? [] { index[name]?.remove(url) }
        let names = Set(tags.map(\.name))
        urlTags[url] = names.isEmpty ? nil : names
        for t in tags {
            colors[t.name] = t.colorIndex
            index[t.name, default: []].insert(url)
        }
    }

    // MARK: Persistence

    public static func defaultStoreURL() -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let appDir = dir.appendingPathComponent("yafm", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("tag-index.json")
    }

    /// On-disk shape: tag name -> (colorIndex?, [path]). Paths, not URLs, so it
    /// round-trips as plain JSON.
    private struct Persisted: Codable {
        var colors: [String: Int]
        var index: [String: [String]]
    }

    public func loadPersisted() async {
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        for (name, c) in p.colors where colors[name] == nil { colors[name] = c }
        for (name, paths) in p.index {
            for path in paths {
                let url = URL(fileURLWithPath: path)
                index[name, default: []].insert(url)
                urlTags[url, default: []].insert(name)
            }
        }
    }

    public func persist() async {
        guard let storeURL else { return }
        var plainColors: [String: Int] = [:]
        for (name, c) in colors { if let c { plainColors[name] = c } }
        let plainIndex = index.mapValues { $0.map(\.path) }
        let p = Persisted(colors: plainColors, index: plainIndex)
        if let data = try? JSONEncoder().encode(p) { try? data.write(to: storeURL) }
    }

    // MARK: xattr bridge

    static func readTags(_ url: URL) -> [Tag] {
        guard let data = readXattr(attr, url),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let strings = raw as? [String], strings.count <= 64
        else { return [] }
        return strings.map { entry in
            let parts = entry.components(separatedBy: "\n")
            return Tag(name: parts[0], colorIndex: parts.count > 1 ? Int(parts[1]) : nil)
        }
    }

    static func writeTags(_ tags: [Tag], _ url: URL) throws {
        let strings = tags.map { tag -> String in
            if let c = tag.colorIndex { return "\(tag.name)\n\(c)" }
            return tag.name
        }
        if strings.isEmpty {
            removeXattr(attr, url)
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0)
        try writeXattr(attr, data, url)
    }

    // Low-level get/set/removexattr wrappers.
    static func readXattr(_ name: String, _ url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let len = getxattr(path, name, nil, 0, 0, 0)
            // Cap at the local APFS per-attribute limit (128 KiB). Network
            // filesystems enforce no cap; refuse to allocate attacker-sized blobs.
            if len <= 0 || len > (1 << 17) { return nil }
            var buf = Data(count: len)
            let got = buf.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, len, 0, 0) }
            return got >= 0 ? buf : nil
        }
    }

    static func writeXattr(_ name: String, _ data: Data, _ url: URL) throws {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileNoSuchFile) }
            let rc = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
            if rc != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    @discardableResult
    static func removeXattr(_ name: String, _ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return removexattr(path, name, 0) == 0
        }
    }
}

// MARK: - Native tag color palette (matches Finder's 0...7)

public extension Tag {
    /// Finder's fixed palette. Index 0 = none.
    static let colorNames = ["None", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]

    var colorName: String? {
        guard let i = colorIndex, i >= 0, i < Self.colorNames.count else { return nil }
        return Self.colorNames[i]
    }
}
