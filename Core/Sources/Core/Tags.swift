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
}

public actor TagService: TagServing {
    private static let attr = "com.apple.metadata:_kMDItemUserTags"

    /// tag name -> color (last writer wins) and -> set of URLs.
    private var colors: [String: Int?] = [:]
    private var index: [String: Set<URL>] = [:]

    public init() {}

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
        colors.map { Tag(name: $0.key, colorIndex: $0.value ?? nil) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func entries(taggedWith tag: Tag) async -> [URL] {
        Array(index[tag.name] ?? [])
    }

    /// Walk `roots` shallowly-recursively, reading native tags into the index.
    /// Bounded + yields periodically so it never starves foreground tag reads.
    public func index(roots: [URL]) async {
        let fm = FileManager.default
        var seen = 0
        let limit = 50_000
        for root in roots {
            guard let en = fm.enumerator(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let url = en.nextObject() as? URL {
                if Task.isCancelled { return }
                let tags = Self.readTags(url)
                if !tags.isEmpty { reindex(url, tags) }
                seen += 1
                if seen >= limit { return }
                if seen % 256 == 0 { await Task.yield() }
            }
        }
    }

    private func reindex(_ url: URL, _ tags: [Tag]) {
        // Drop stale memberships for this url, then re-add.
        for key in index.keys { index[key]?.remove(url) }
        for t in tags {
            colors[t.name] = t.colorIndex
            index[t.name, default: []].insert(url)
        }
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
