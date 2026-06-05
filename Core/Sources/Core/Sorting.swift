import Foundation

// MARK: - Sorting

public enum SortKey: String, Sendable, CaseIterable {
    case name, size, modified, kind
}

public struct SortOrder: Sendable, Equatable {
    public var key: SortKey
    public var ascending: Bool
    public init(key: SortKey = .name, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }
}

public extension Array where Element == FSEntry {
    /// Directories first, then by the chosen key. Stable, locale-aware.
    func sorted(by order: SortOrder) -> [FSEntry] {
        sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let result: Bool
            switch order.key {
            case .name:
                result = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size:
                // Unknown sizes (nil) sort below 0-byte files so they don't
                // interleave ambiguously with real empties.
                result = (a.size ?? -1) < (b.size ?? -1)
            case .modified:
                result = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            case .kind:
                result = a.url.pathExtension.localizedStandardCompare(b.url.pathExtension) == .orderedAscending
            }
            return order.ascending ? result : !result
        }
    }
}

// MARK: - Bulk rename (v0.2)

/// A pure, previewable rename plan: regex find/replace + optional sequence.
public struct RenameRule: Sendable {
    public var pattern: String
    public var replacement: String
    public var useRegex: Bool
    public var sequenceStart: Int?     // `#` in replacement -> zero-padded counter

    public init(pattern: String, replacement: String, useRegex: Bool = true, sequenceStart: Int? = nil) {
        self.pattern = pattern
        self.replacement = replacement
        self.useRegex = useRegex
        self.sequenceStart = sequenceStart
    }

    /// Returns (original, proposed) name pairs without touching disk.
    public func preview(_ names: [String]) -> [(from: String, to: String)] {
        var counter = sequenceStart ?? 0
        let width = max(String(names.count).count, 2)
        // Cap pattern length to blunt pathological regexes evaluated live as the
        // user types (M-13); filenames themselves are filesystem-bounded.
        let regex = (useRegex && pattern.count <= 512) ? try? NSRegularExpression(pattern: pattern) : nil
        return names.map { name in
            var out: String
            if useRegex, let regex {
                let range = NSRange(name.startIndex..., in: name)
                out = regex.stringByReplacingMatches(in: name, range: range, withTemplate: replacement)
            } else {
                out = pattern.isEmpty ? name : name.replacingOccurrences(of: pattern, with: replacement)
            }
            if sequenceStart != nil {
                let seq = String(format: "%0\(width)d", counter)
                out = out.replacingOccurrences(of: "#", with: seq)
                counter += 1
            }
            return (name, out)
        }
    }
}

// MARK: - Color coding (v0.2): rules map an entry to a color

/// Immutable, thread-safe compiled regex. `NSRegularExpression` is documented
/// thread-safe but isn't `Sendable`-annotated, so wrap it.
public struct CompiledRegex: @unchecked Sendable {
    public let regex: NSRegularExpression?
    /// Cap pattern length to blunt pathological/ReDoS patterns (M-13). Names are
    /// already bounded by the filesystem (≤255), so worst-case backtracking on a
    /// single match stays bounded.
    public init(_ pattern: String) {
        regex = pattern.count <= 512 ? try? NSRegularExpression(pattern: pattern) : nil
    }
    public func matches(_ s: String) -> Bool {
        guard let regex, s.utf16.count <= 4096 else { return false }
        return regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

public struct ColorRule: Sendable, Identifiable {
    public enum Match: Sendable {
        case ext(Set<String>)          // by file extension
        case directory
        case tag(String)               // has a named tag
        case nameRegex(String)
    }
    public let id: UUID
    public let match: Match
    /// SwiftUI-agnostic: store a name the UI maps to a Color.
    public let colorName: String
    /// Precompiled once at init — `matches` is called per file per render, so
    /// compiling in the hot path (H-13) would thrash the regex engine.
    private let compiled: CompiledRegex?

    public init(id: UUID = UUID(), match: Match, colorName: String) {
        self.id = id
        self.match = match
        self.colorName = colorName
        if case .nameRegex(let pat) = match { compiled = CompiledRegex(pat) }
        else { compiled = nil }
    }

    public func matches(_ entry: FSEntry) -> Bool {
        switch match {
        case .ext(let set): return set.contains(entry.url.pathExtension.lowercased())
        case .directory: return entry.isDirectory
        case .tag(let name): return entry.tags.contains { $0.name == name }
        case .nameRegex: return compiled?.matches(entry.name) ?? false
        }
    }
}

public struct ColorCoder: Sendable {
    public var rules: [ColorRule]
    public init(rules: [ColorRule] = ColorCoder.defaults) { self.rules = rules }

    /// First matching rule wins; nil = default color.
    public func colorName(for entry: FSEntry) -> String? {
        rules.first { $0.matches(entry) }?.colorName
    }

    public static let defaults: [ColorRule] = [
        ColorRule(match: .ext(["jpg", "jpeg", "png", "gif", "heic", "webp", "svg"]), colorName: "Purple"),
        ColorRule(match: .ext(["mov", "mp4", "m4v", "avi", "mkv"]), colorName: "Blue"),
        ColorRule(match: .ext(["zip", "tar", "gz", "dmg", "7z"]), colorName: "Orange"),
        ColorRule(match: .ext(["swift", "js", "ts", "py", "rs", "go", "c", "h"]), colorName: "Green"),
        ColorRule(match: .ext(["md", "txt", "pdf", "rtf", "doc", "docx", "pages"]), colorName: "Gray"),
    ]
}

// MARK: - Bookmarks / favorites (v0.2)

public struct Bookmark: Identifiable, Sendable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var path: String
    public init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
    /// Only ever resolve absolute paths; an empty/relative bookmark path would
    /// otherwise resolve against the CWD (L-9). Falls back to Home.
    public var url: URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : FileManager.default.homeDirectoryForCurrentUser
    }
}
