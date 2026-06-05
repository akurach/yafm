import Foundation

// MARK: - Search (Spotlight + own fallback)

/// Finds files by name within a directory. Uses Spotlight (`mdfind -onlyin`)
/// first — instant and indexed — and falls back to our own recursive
/// name-substring walk when Spotlight returns nothing (a location it hasn't
/// indexed: a freshly mounted disk, a temp tree, or indexing disabled).
///
/// Name-only by design for v0.3: it answers "where is that file" without the
/// surprise of full-text hits. Content search can layer on later.
/// What to match: file names (Spotlight + walk) or file *contents* (grep).
public enum SearchMode: String, Sendable, CaseIterable, Identifiable {
    case name, content
    public var id: String { rawValue }
}

public struct SearchService: Sendable {
    public init() {}

    /// Per-file byte cap for content search — skip anything bigger so a giant
    /// log/binary can't stall the grep (the never-freeze contract).
    static let contentFileSizeCap: Int = 8 * 1024 * 1024   // 8 MB

    // MARK: Streaming API (v0.6) — results arrive as they're found, cancellable

    /// Stream matching file URLs for `mode`, scoped to `directory`. Each hit is
    /// yielded the moment it's found so the results pane fills progressively and
    /// a slow tree never blocks behind a final array. Honours task cancellation
    /// (drop the stream → the walk stops) and is bounded by `limit`.
    public func searchStream(_ query: String, in directory: URL,
                             mode: SearchMode, limit: Int = 2000) -> AsyncStream<URL> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return AsyncStream { continuation in
            guard !trimmed.isEmpty else { continuation.finish(); return }
            let task = Task.detached(priority: .userInitiated) {
                switch mode {
                case .name:
                    // Spotlight is already-indexed and fast; emit its hits, then
                    // fall back to our own walk only if it found nothing.
                    let viaSpotlight = Self.spotlight(trimmed, in: directory, limit: limit)
                    if !viaSpotlight.isEmpty {
                        for url in viaSpotlight { if Task.isCancelled { break }; continuation.yield(url) }
                    } else {
                        Self.walkStream(trimmed, in: directory, limit: limit) { continuation.yield($0) }
                    }
                case .content:
                    Self.grepStream(trimmed, in: directory, limit: limit) { continuation.yield($0) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

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

    /// Streaming name walk — same as `walk` but emits each hit immediately.
    static func walkStream(_ query: String, in directory: URL, limit: Int,
                           emit: (URL) -> Void) {
        let needle = query.lowercased()
        let fm = FileManager.default
        guard let en = fm.enumerator(at: directory, includingPropertiesForKeys: nil,
                                     options: [.skipsPackageDescendants]) else { return }
        var count = 0
        while let url = en.nextObject() as? URL {
            if Task.isCancelled || count >= limit { break }
            if url.lastPathComponent.lowercased().contains(needle) { emit(url); count += 1 }
        }
    }

    /// Grep-in-files: recursively scan regular files for a case-insensitive
    /// substring in their contents, emitting each matching file once. Skips
    /// directories, packages, oversized files, and anything that doesn't decode
    /// as UTF-8 text (a cheap binary guard — a NUL byte in the first chunk).
    /// Bounded by `limit`; cancellable between files.
    static func grepStream(_ query: String, in directory: URL, limit: Int,
                           emit: (URL) -> Void) {
        let needle = query.lowercased()
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else { return }
        var count = 0
        while let url = en.nextObject() as? URL {
            if Task.isCancelled || count >= limit { break }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            if let size = values?.fileSize, size > contentFileSizeCap { continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            if data.prefix(1024).contains(0) { continue }   // looks binary → skip
            let text = String(decoding: data, as: UTF8.self).lowercased()
            if text.contains(needle) { emit(url); count += 1 }
        }
    }
}
