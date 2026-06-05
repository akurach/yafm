import Foundation

// MARK: - Search (Spotlight + own fallback)

/// Finds files by name within a directory. Uses Spotlight (`mdfind -onlyin`)
/// first — instant and indexed — and falls back to our own recursive
/// name-substring walk when Spotlight returns nothing (a location it hasn't
/// indexed: a freshly mounted disk, a temp tree, or indexing disabled).
///
/// Name-only by design for v0.3: it answers "where is that file" without the
/// surprise of full-text hits. Content search can layer on later.
public struct SearchService: Sendable {
    public init() {}

    public func search(_ query: String, in directory: URL, limit: Int = 2000) async -> [URL] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let viaSpotlight = Self.spotlight(trimmed, in: directory, limit: limit)
            if !viaSpotlight.isEmpty { return viaSpotlight }
            return Self.walk(trimmed, in: directory, limit: limit)
        }.value
    }

    /// `mdfind -onlyin <dir> 'kMDItemFSName == "*q*"cd'` — case/diacritic-
    /// insensitive filename contains. Spotlight escapes nothing for us, so the
    /// query is built with the glob operators it expects and the user's text is
    /// quote-sanitised.
    private static func spotlight(_ query: String, in directory: URL, limit: Int) -> [URL] {
        let safe = query.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
        guard !safe.isEmpty else { return [] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        proc.arguments = ["-onlyin", directory.path, "kMDItemFSName == \"*\(safe)*\"cd"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .prefix(limit)
            .map { URL(fileURLWithPath: String($0)) }
    }

    /// Our own walk: recursive, case-insensitive substring on the file name.
    /// Bounded by `limit` so a huge tree can't run away. Honours cancellation.
    private static func walk(_ query: String, in directory: URL, limit: Int) -> [URL] {
        let needle = query.lowercased()
        var out: [URL] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        ) else { return [] }
        while let url = en.nextObject() as? URL {
            if Task.isCancelled || out.count >= limit { break }
            if url.lastPathComponent.lowercased().contains(needle) { out.append(url) }
        }
        return out
    }
}
