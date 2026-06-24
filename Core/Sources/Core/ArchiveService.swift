import Foundation

// MARK: - Archive write (v0.9.8 — universal extract + configurable compress)

/// A wrapper over the archive tools that ship with macOS — `bsdtar`
/// (libarchive), `zip`, `unzip`, `ditto`, `gzip`, `bzip2`. **No third-party
/// dependency, nothing to install.** libarchive gives us read support for
/// *practically any* archive (zip, 7-zip, RAR4, tar + gzip/bzip2/xz/zstd, cpio,
/// iso, cab, lha, xar, …) through a single code path, including password-
/// protected zip/7-zip. The write side offers zip (with optional password +
/// level) and the tar family. Every call runs off the main actor.
public actor ArchiveService {
    public init() {}

    public enum ArchiveError: LocalizedError, Equatable {
        case needsPassword          // encrypted and no password supplied
        case wrongPassword          // a password was supplied but rejected
        case unsupported(String)
        case toolFailed(String)
        public var errorDescription: String? {
            switch self {
            case .needsPassword:      return "This archive is password-protected."
            case .wrongPassword:      return "Incorrect password."
            case .unsupported(let n): return "Can't handle \(n): unsupported format."
            case .toolFailed(let m):  return m
            }
        }
    }

    /// A passphrase we hand to `bsdtar` when the user gave none, so it never drops
    /// into an interactive "Enter passphrase:" loop on an encrypted archive. It's
    /// ignored on unencrypted archives and rejected on encrypted ones (→ we then
    /// surface `.needsPassword`). Must be non-empty and realistically never a real
    /// password.
    private static let noPasswordProbe = "\u{1}yafm-no-password\u{1}"

    /// Extensions we offer **Extract Here** for. Extraction itself goes through
    /// libarchive, which auto-detects the real format regardless of extension.
    private static let extractable: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz",
        "zst", "zstd", "cpio", "iso", "cab", "lha", "lzh", "ar", "xar", "pax", "cbz", "cbr",
    ]

    public static func canExtract(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        if n.hasSuffix(".tar.gz") || n.hasSuffix(".tar.bz2") || n.hasSuffix(".tar.xz")
            || n.hasSuffix(".tar.zst") { return true }
        return extractable.contains(url.pathExtension.lowercased())
    }

    // MARK: Extract

    /// Unpack `archive` into a sibling folder named after it (collision-suffixed),
    /// so files never spray into the current directory. Throws `.needsPassword`
    /// when the archive is encrypted and `password` is nil, or `.wrongPassword`
    /// when a supplied password is rejected — the caller prompts and retries.
    /// Returns the folder created.
    @discardableResult
    public func extract(_ archive: URL, password: String? = nil) async throws -> URL {
        let dest = uniqueSibling(named: baseName(of: archive),
                                 in: archive.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        // A bare gzip/bzip2 of a single file isn't a tar stream — libarchive's
        // `tar -xf` would reject it. Route those to the matching decompressor.
        if let single = bareCompressor(for: archive) {
            do { try await single(archive, dest) }
            catch { try? FileManager.default.removeItem(at: dest); throw error }
            return dest
        }

        do {
            try await run("/usr/bin/tar",
                          ["--passphrase", password ?? Self.noPasswordProbe,
                           "-xf", archive.path, "-C", dest.path])
        } catch let ArchiveError.toolFailed(msg) {
            try? FileManager.default.removeItem(at: dest)
            if Self.looksLikePasswordError(msg) {
                throw password == nil ? ArchiveError.needsPassword : ArchiveError.wrongPassword
            }
            throw ArchiveError.toolFailed(msg)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        return dest
    }

    private static func looksLikePasswordError(_ msg: String) -> Bool {
        let m = msg.lowercased()
        return m.contains("passphrase") || m.contains("password") || m.contains("encrypt")
    }

    /// For a bare `foo.gz` / `foo.bz2` (NOT `foo.tar.gz`), return a closure that
    /// decompresses the single stream into `dest`. nil for everything else.
    private func bareCompressor(for archive: URL) -> ((URL, URL) async throws -> Void)? {
        let n = archive.lastPathComponent.lowercased()
        let isTarred = n.hasSuffix(".tar.gz") || n.hasSuffix(".tgz")
            || n.hasSuffix(".tar.bz2") || n.hasSuffix(".tbz") || n.hasSuffix(".tbz2")
        guard !isTarred else { return nil }
        let inner = archive.deletingPathExtension().lastPathComponent
        if n.hasSuffix(".gz") {
            return { [weak self] arc, dest in
                try await self?.run("/usr/bin/gzip", ["-dkc", arc.path],
                                    redirectingStdoutTo: dest.appendingPathComponent(inner))
            }
        }
        if n.hasSuffix(".bz2") {
            return { [weak self] arc, dest in
                try await self?.run("/usr/bin/bzip2", ["-dkc", arc.path],
                                    redirectingStdoutTo: dest.appendingPathComponent(inner))
            }
        }
        return nil
    }

    // MARK: Compress

    /// The archive kinds we can *create* with system tools.
    public enum CompressionFormat: String, Sendable, CaseIterable, Identifiable {
        case zip, tarGz, tarBz2, tarXz
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .zip:    return "ZIP"
            case .tarGz:  return "TAR + Gzip"
            case .tarBz2: return "TAR + Bzip2"
            case .tarXz:  return "TAR + XZ"
            }
        }
        public var fileExtension: String {
            switch self {
            case .zip: return "zip"; case .tarGz: return "tar.gz"
            case .tarBz2: return "tar.bz2"; case .tarXz: return "tar.xz"
            }
        }
        /// Only the zip writer supports a password with the system tools.
        public var supportsPassword: Bool { self == .zip }
        /// A 0–9 level slider is meaningful for zip and gzip; bzip2/xz use a default.
        public var supportsLevel: Bool { self == .zip || self == .tarGz }
    }

    /// Create `dest` from `items` (all in the same parent). `level` is 0–9 (clamped);
    /// `password` only applies to `.zip`. Returns the archive created.
    @discardableResult
    public func compress(_ items: [URL], to dest: URL, format: CompressionFormat,
                         level: Int = 6, password: String? = nil) async throws -> URL {
        guard !items.isEmpty else { throw ArchiveError.unsupported("(nothing selected)") }
        let parent = items[0].deletingLastPathComponent().path
        let names = items.map(\.lastPathComponent)
        let lvl = max(0, min(9, level))

        switch format {
        case .zip:
            var args = ["-r", "-q", "-\(lvl)"]
            if let password, !password.isEmpty { args += ["-P", password] }
            try await run("/usr/bin/zip", args + [dest.path] + names, cwd: parent)
        case .tarGz, .tarBz2, .tarXz:
            let flag: String = format == .tarGz ? "-czf" : (format == .tarBz2 ? "-cjf" : "-cJf")
            var args: [String] = []
            if format.supportsLevel { args += ["--options", "gzip:compression-level=\(lvl)"] }
            args += [flag, dest.path, "-C", parent] + names
            try await run("/usr/bin/tar", args)
        }
        return dest
    }

    // MARK: Helpers

    /// Strip a (possibly double) archive extension: `foo.tar.gz` → `foo`.
    private func baseName(of url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tgz", ".tbz",
                       ".tbz2", ".txz", ".tar", ".zip", ".7z", ".rar", ".gz", ".bz2",
                       ".xz", ".zst", ".cpio", ".iso", ".cbz", ".cbr"] {
            if name.lowercased().hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count)); break
            }
        }
        return name.isEmpty ? "Archive" : name
    }

    private func uniqueSibling(named base: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// Run a tool to completion off the main actor; throw `.toolFailed` with the
    /// captured stderr on a nonzero exit. `stdin` is closed so a tool can never
    /// block on an interactive prompt. Resumes exactly once.
    private func run(_ launchPath: String, _ args: [String], cwd: String? = nil,
                     redirectingStdoutTo outFile: URL? = nil) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launchPath)
            proc.arguments = args
            if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            proc.standardInput = FileHandle.nullDevice
            let errPipe = Pipe()
            proc.standardError = errPipe
            if let outFile {
                FileManager.default.createFile(atPath: outFile.path, contents: nil)
                proc.standardOutput = try? FileHandle(forWritingTo: outFile)
            }
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
