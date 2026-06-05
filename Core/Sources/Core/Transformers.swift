import Foundation

// MARK: - Transformers & previewers (v0.9 — the last VISION extension points)

/// A name transformer: a reusable bulk-rename rule or converter. The last of the
/// VISION extension points, now safe to open atop the v0.5 async-value machinery
/// and the v0.8 capability boundary. A transformer is pure — it maps a name (and
/// its position in the batch) to a new name — so it's trivially testable and can
/// be contributed by a first-party feature or, later, a capability-bounded plugin.
public protocol Transformer: Sendable {
    var id: String { get }
    var title: String { get }
    /// Map `name` (the full filename) to a new name. `index` is the 0-based
    /// position in the selection, for numbering rules. Returning the same name
    /// is a no-op.
    func transform(name: String, index: Int) -> String
}

/// Lowercase the whole filename. The simplest built-in, and the reference shape.
public struct LowercaseTransformer: Transformer {
    public let id = "transform.lowercase"
    public let title = "lowercase"
    public init() {}
    public func transform(name: String, index: Int) -> String { name.lowercased() }
}

/// Prefix a zero-padded sequence number: `001 - name.ext`. Width grows with the
/// batch but is at least 3. Extension is preserved.
public struct SequenceTransformer: Transformer {
    public let id = "transform.sequence"
    public let title = "Number sequentially"
    public let start: Int
    public let width: Int
    public init(start: Int = 1, width: Int = 3) {
        self.start = start
        self.width = max(1, width)
    }
    public func transform(name: String, index: Int) -> String {
        let n = String(start + index)
        let padded = String(repeating: "0", count: max(0, width - n.count)) + n
        return "\(padded) - \(name)"
    }
}

/// Replace spaces with a separator (default "-") — a common tidy-up converter.
public struct SpaceReplaceTransformer: Transformer {
    public let id = "transform.despace"
    public let title = "Replace spaces"
    public let separator: String
    public init(separator: String = "-") { self.separator = separator }
    public func transform(name: String, index: Int) -> String {
        name.replacingOccurrences(of: " ", with: separator)
    }
}

/// Apply a transformer across a batch, preserving order. Pure helper the
/// bulk-rename UI calls to build its live preview.
public func applyTransformer(_ t: Transformer, to names: [String]) -> [String] {
    names.enumerated().map { t.transform(name: $0.element, index: $0.offset) }
}

// MARK: - Custom previewers

/// A custom previewer contributed for file types QuickLook doesn't cover well
/// (a log tail, a CSV table, a plugin-rendered view). The host asks `canPreview`
/// by extension; rendering is wired at the UI layer. Pure metadata here so Core
/// stays UI-free and the contract is testable.
public protocol Previewer: Sendable {
    var id: String { get }
    var title: String { get }
    /// Lowercased extensions this previewer handles (e.g. ["log", "csv"]).
    var handledExtensions: [String] { get }
    func canPreview(extension ext: String) -> Bool
}

public extension Previewer {
    func canPreview(extension ext: String) -> Bool {
        handledExtensions.contains(ext.lowercased())
    }
}

/// Built-in plain-text previewer for extensionless / log-like files.
public struct TextPreviewer: Previewer {
    public let id = "preview.text"
    public let title = "Plain Text"
    public let handledExtensions = ["log", "csv", "tsv", "ini", "conf", "env"]
    public init() {}
}
