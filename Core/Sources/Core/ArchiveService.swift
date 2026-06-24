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

    /// Path to the bundled (or system) `7zz` — 7-Zip's CLI — used for creating
    /// `.7z` and for the most robust RAR/7z extraction. Resolved once: the binary
    /// shipped inside the app at `Resources/bin/7zz`, then a `YAFM_7ZZ` dev
    /// override, then a Homebrew/`/usr/local` install. nil if none is found.
    public static let sevenZipPath: String? = {
        let fm = FileManager.default
        if let url = Bundle.main.resourceURL?.appendingPathComponent("bin/7zz"),
           fm.isExecutableFile(atPath: url.path) { return url.path }
        if let env = ProcessInfo.processInfo.environment["YAFM_7ZZ"],
           fm.isExecutableFile(atPath: env) { return env }
        for p in ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz",
                  "/opt/homebrew/bin/7z", "/usr/local/bin/7z"]
        where fm.isExecutableFile(atPath: p) { return p }
        return nil
    }()

    public static var sevenZipAvailable: Bool { sevenZipPath != nil }

    /// Formats where 7-Zip is the better (or only) reader — route these to `7zz`
    /// when it's available, falling back to libarchive otherwise.
    private static func prefersSevenZip(_ url: URL) -> Bool {
        ["rar", "cbr", "7z"].contains(url.pathExtension.lowercased())
    }

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

        // RAR (esp. v5) and 7z extract most reliably through 7-Zip when present.
        let useSevenZip = Self.prefersSevenZip(archive) && Self.sevenZipAvailable
        do {
            if useSevenZip, let z = Self.sevenZipPath {
                // -p<pass> with a value disables the interactive prompt; -y = assume
                // yes; -bb0/-bso0 quiet. A wrong/sentinel pass fails cleanly.
                try await run(z, ["x", archive.path, "-o\(dest.path)", "-y", "-bso0",
                                  "-p\(password ?? Self.noPasswordProbe)"])
            } else {
                try await run("/usr/bin/tar",
                              ["--passphrase", password ?? Self.noPasswordProbe,
                               "-xf", archive.path, "-C", dest.path])
            }
        } catch let ArchiveError.toolFailed(msg) {
            try? FileManager.default.removeItem(at: dest)
            if Self.looksLikePasswordError(msg) {
                throw password == nil ? ArchiveError.needsPassword : ArchiveError.wrongPassword
            }
            // A RAR with no 7-Zip available is the one format we genuinely can't do.
            if Self.prefersSevenZip(archive) && !Self.sevenZipAvailable {
                throw ArchiveError.unsupported(archive.lastPathComponent + " (needs 7-Zip)")
            }
            throw ArchiveError.toolFailed(msg)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        return flattenSingleRoot(dest, beside: archive)
    }

    /// If the extraction produced exactly one top-level entry, the wrap folder is
    /// redundant — lift that entry up beside the archive (collision-suffixed) and
    /// drop the empty wrapper, matching the "wrap only if necessary" behaviour.
    private func flattenSingleRoot(_ dest: URL, beside archive: URL) -> URL {
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]),
              kids.count == 1 else { return dest }
        let only = kids[0]
        let target = uniqueSibling(named: only.lastPathComponent,
                                   in: archive.deletingLastPathComponent())
        do {
            try fm.moveItem(at: only, to: target)
            try? fm.removeItem(at: dest)
            return target
        } catch { return dest }
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
        case zip, sevenZip, tarGz, tarBz2, tarXz
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .zip:      return "ZIP"
            case .sevenZip: return "7z"
            case .tarGz:    return "TAR + Gzip"
            case .tarBz2:   return "TAR + Bzip2"
            case .tarXz:    return "TAR + XZ"
            }
        }
        public var fileExtension: String {
            switch self {
            case .zip: return "zip"; case .sevenZip: return "7z"; case .tarGz: return "tar.gz"
            case .tarBz2: return "tar.bz2"; case .tarXz: return "tar.xz"
            }
        }
        /// zip (weak PKZip) and 7z (strong AES-256) support a password.
        public var supportsPassword: Bool { self == .zip || self == .sevenZip }
        /// A 0–9 level slider is meaningful for zip, 7z, and gzip.
        public var supportsLevel: Bool { self == .zip || self == .sevenZip || self == .tarGz }
        /// 7z creation needs the bundled 7-Zip; everything else uses always-present tools.
        public var needsSevenZip: Bool { self == .sevenZip }
    }

    /// The formats offerable right now — drops `.sevenZip` if no 7-Zip is found.
    public static var availableFormats: [CompressionFormat] {
        CompressionFormat.allCases.filter { !$0.needsSevenZip || sevenZipAvailable }
    }

    /// Options for **Compress**, mirroring the per-action dialog.
    public struct CompressOptions: Sendable {
        public var format: CompressionFormat
        public var level: Int                 // 0–9 (clamped)
        public var password: String?          // zip / 7z only
        public var solid: Bool                // 7z solid block (better ratio)
        public var volumeSizeMB: Int?         // split into N-MB volumes (zip / 7z)
        public var excludeHidden: Bool        // skip dotfiles + .DS_Store
        public var excludeVCS: Bool           // skip .git / .svn
        public init(format: CompressionFormat, level: Int = 6, password: String? = nil,
                    solid: Bool = false, volumeSizeMB: Int? = nil,
                    excludeHidden: Bool = false, excludeVCS: Bool = false) {
            self.format = format; self.level = level; self.password = password
            self.solid = solid; self.volumeSizeMB = volumeSizeMB
            self.excludeHidden = excludeHidden; self.excludeVCS = excludeVCS
        }
    }

    /// Create `dest` from `items` (all in the same parent) per `options`. Returns
    /// the archive created (volume-splitting yields `dest` as the first part).
    @discardableResult
    public func compress(_ items: [URL], to dest: URL, options o: CompressOptions) async throws -> URL {
        guard !items.isEmpty else { throw ArchiveError.unsupported("(nothing selected)") }
        let parent = items[0].deletingLastPathComponent().path
        let names = items.map(\.lastPathComponent)
        let lvl = max(0, min(9, o.level))
        let pw = (o.password?.isEmpty == false) ? o.password : nil

        switch o.format {
        case .zip:
            var args = ["-r", "-q", "-\(lvl)"]
            if let pw { args += ["-P", pw] }
            if let mb = o.volumeSizeMB, mb > 0 { args += ["-s", "\(mb)m"] }
            args += [dest.path] + names
            // `zip -x` exclusion globs must trail the file list.
            let excludes = zipExcludes(o)
            if !excludes.isEmpty { args += ["-x"] + excludes }
            try await run("/usr/bin/zip", args, cwd: parent)
        case .sevenZip:
            guard let z = Self.sevenZipPath else { throw ArchiveError.unsupported("7z (needs 7-Zip)") }
            var args = ["a", "-t7z", "-mx=\(lvl)", "-ms=\(o.solid ? "on" : "off")", "-y", "-bso0"]
            if let pw { args += ["-p\(pw)", "-mhe=on"] }
            if let mb = o.volumeSizeMB, mb > 0 { args += ["-v\(mb)m"] }
            if o.excludeHidden { args += ["-xr!.*"] }
            if o.excludeVCS { args += ["-xr!.git", "-xr!.svn"] }
            try await run(z, args + [dest.path] + names, cwd: parent)
        case .tarGz, .tarBz2, .tarXz:
            let flag: String = o.format == .tarGz ? "-czf" : (o.format == .tarBz2 ? "-cjf" : "-cJf")
            var args: [String] = []
            if o.format.supportsLevel { args += ["--options", "gzip:compression-level=\(lvl)"] }
            if o.excludeHidden { args += ["--exclude", ".*", "--exclude", ".DS_Store"] }
            if o.excludeVCS { args += ["--exclude", ".git", "--exclude", ".svn"] }
            args += [flag, dest.path, "-C", parent] + names
            try await run("/usr/bin/tar", args)
        }
        return dest
    }

    /// `zip -x` exclusion globs (matched against archive-relative paths).
    private func zipExcludes(_ o: CompressOptions) -> [String] {
        var pats: [String] = []
        if o.excludeHidden { pats += [".*", "*/.*", "*/.DS_Store", ".DS_Store"] }
        if o.excludeVCS { pats += ["*.git/*", "*.git", "*.svn/*", "*.svn"] }
        return pats
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
