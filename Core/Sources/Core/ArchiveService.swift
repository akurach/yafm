import Foundation

// MARK: - Archive write (v0.9.8 — extract / compress)

/// Creates and unpacks archives by shelling out to the system tools that ship
/// with macOS (`ditto`, `tar`) — no third-party dependency. Read-only *browsing*
/// of a `.zip` still lives in `ArchiveFileSystem`; this is the write side:
/// **Extract here** and **Compress**. Each call runs off the main actor.
public actor ArchiveService {
    public init() {}

    public enum ArchiveError: LocalizedError {
        case unsupported(String)
        case toolFailed(String)
        public var errorDescription: String? {
            switch self {
            case .unsupported(let n): return "Can't extract \(n): unsupported format."
            case .toolFailed(let m):  return m
            }
        }
    }

    /// Extensions we can unpack. zip via `ditto`; tar family via `tar`.
    public static func canExtract(_ url: URL) -> Bool {
        extractKind(for: url) != nil
    }

    private enum Kind { case zip, tar }
    private static func extractKind(for url: URL) -> Kind? {
        let n = url.lastPathComponent.lowercased()
        if n.hasSuffix(".zip") { return .zip }
        if n.hasSuffix(".tar") || n.hasSuffix(".tar.gz") || n.hasSuffix(".tgz")
            || n.hasSuffix(".tar.bz2") || n.hasSuffix(".tbz") { return .tar }
        return nil
    }

    /// Unpack `archive` into a sibling folder named after it (collision-suffixed),
    /// so files never spray into the current directory. Returns the folder created.
    @discardableResult
    public func extract(_ archive: URL) async throws -> URL {
        guard let kind = Self.extractKind(for: archive) else {
            throw ArchiveError.unsupported(archive.lastPathComponent)
        }
        let dest = uniqueFolder(named: baseName(of: archive),
                                in: archive.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        switch kind {
        case .zip:
            try await run("/usr/bin/ditto", ["-x", "-k", archive.path, dest.path])
        case .tar:
            try await run("/usr/bin/tar", ["-xf", archive.path, "-C", dest.path])
        }
        return dest
    }

    /// Compress `items` (all expected in the same parent) into a `.zip` beside
    /// them. Uses `ditto --keepParent` for a single item (preserves the top folder)
    /// and `zip -r` with relative names for several. Returns the archive created.
    @discardableResult
    public func compress(_ items: [URL], to dest: URL) async throws -> URL {
        guard !items.isEmpty else { throw ArchiveError.unsupported("(nothing selected)") }
        if items.count == 1 {
            // `--keepParent` preserves a folder's top directory inside the zip, but
            // for a single *file* it would nest it under the source dir's name — so
            // only keep the parent when compressing a directory.
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: items[0].path, isDirectory: &isDir)
            let opts = isDir.boolValue ? ["-c", "-k", "--sequesterRsrc", "--keepParent"]
                                       : ["-c", "-k", "--sequesterRsrc"]
            try await run("/usr/bin/ditto", opts + [items[0].path, dest.path])
        } else {
            // zip resolves names relative to the working directory — run it in the
            // common parent so the archive stores plain entry names, not full paths.
            let parent = items[0].deletingLastPathComponent().path
            try await run("/usr/bin/zip", ["-r", "-q", dest.path] + items.map(\.lastPathComponent),
                          cwd: parent)
        }
        return dest
    }

    // MARK: Helpers

    /// Strip a (possibly double) archive extension: `foo.tar.gz` → `foo`.
    private func baseName(of url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tgz", ".tbz", ".tar", ".zip"] {
            if name.lowercased().hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count)); break
            }
        }
        return name.isEmpty ? "Archive" : name
    }

    private func uniqueFolder(named base: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// Run a tool to completion off the main actor; throw with captured stderr on
    /// a nonzero exit. Resumes exactly once via the termination handler.
    private func run(_ launchPath: String, _ args: [String], cwd: String? = nil) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launchPath)
            proc.arguments = args
            if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let errPipe = Pipe()
            proc.standardError = errPipe
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 { cont.resume() }
                else {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(throwing: ArchiveError.toolFailed(
                        msg.isEmpty ? "\(launchPath) exited \(p.terminationStatus)" : msg))
                }
            }
            do { try proc.run() } catch { cont.resume(throwing: error) }
        }
    }
}
