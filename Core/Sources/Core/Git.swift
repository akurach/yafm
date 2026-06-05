import Foundation

// MARK: - Git status (first-party native "plugin column")

/// Computes a short VCS status marker per file in a directory by shelling out to
/// `git`. First-party and **native** — VISION allows heavy first-party features
/// to be native yet appear in the same plugin registry as JS columns. Running
/// `git` is exactly the kind of capability the JS sandbox deliberately withholds,
/// so this lives on the Swift side and surfaces through a `PluginColumn`.
///
/// Markers (Finder-ish, single glyph): `M` modified · `A` added/staged ·
/// `?` untracked · `D` deleted · `•` a folder containing changes · "" clean.
public actor GitStatusService {
    public init() {}

    /// Status for the **immediate children** of `directory`, keyed by file name.
    /// Empty when `directory` isn't inside a git work tree. Recomputed on every
    /// call (listings are user-initiated and infrequent) so it never goes stale.
    public func status(forDirectory directory: URL) async -> [String: String] {
        await Task.detached(priority: .utility) {
            guard let top = Self.git(["rev-parse", "--show-toplevel"], in: directory)?
                .first.map({ URL(fileURLWithPath: $0) })
            else { return [:] }

            // `-z` → NUL-separated, path stays literal (no quoting/escaping games).
            guard let raw = Self.gitRaw(["status", "--porcelain", "-z"], in: directory)
            else { return [:] }

            let dirPath = directory.standardizedFileURL.path
            let topPath = top.standardizedFileURL.path
            // Each record is "XY <path>"; renames add a second NUL'd path we skip.
            let records = raw.split(separator: "\0", omittingEmptySubsequences: true)
            var out: [String: String] = [:]
            var skipNext = false
            for record in records {
                if skipNext { skipNext = false; continue }
                guard record.count > 3 else { continue }
                let code = String(record.prefix(2))
                let rel = String(record.dropFirst(3))
                if code.first == "R" || code.first == "C" { skipNext = true }  // rename/copy origin
                let absolute = URL(fileURLWithPath: topPath + "/" + rel).standardizedFileURL.path
                guard absolute.hasPrefix(dirPath + "/") else { continue }
                let tail = String(absolute.dropFirst(dirPath.count + 1))
                let marker = Self.marker(for: code)
                if let slash = tail.firstIndex(of: "/") {
                    // Change lives inside a subfolder → roll up onto that folder.
                    let child = String(tail[..<slash])
                    if out[child] == nil { out[child] = "•" }
                } else {
                    out[tail] = marker   // direct child file: exact marker
                }
            }
            return out
        }.value
    }

    /// Collapse a two-char porcelain code into one glyph.
    private static func marker(for code: String) -> String {
        if code == "??" { return "?" }
        if code.contains("A") { return "A" }
        if code.contains("D") { return "D" }
        if code.contains("M") || code.contains("R") || code.contains("C") { return "M" }
        return "•"
    }

    /// Run `git -C dir args`, return stdout split into trimmed lines, or nil on a
    /// non-zero exit / launch failure.
    private static func git(_ args: [String], in dir: URL) -> [String]? {
        gitRaw(args, in: dir)?.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Run `git -C dir args`, return raw stdout (nil on non-zero exit / no git).
    private static func gitRaw(_ args: [String], in dir: URL) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir.path] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        // No git installed / not launchable → silently "not a repo".
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
