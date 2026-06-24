import Foundation

// MARK: - Archive mounting (v0.8) — read-only .zip as a virtual filesystem

/// Where an `archive://` URL points: the on-disk `.zip` plus the path *inside*
/// it. Same shape as `SMBLocation` — a container + a subpath — so it rides the
/// same `FileSystemRouter` seam. The zip path travels in the `zip` query item so
/// it survives slashes/spaces; the inner path is the URL path.
public struct ArchiveLocation: Equatable, Sendable {
    public let zipURL: URL          // file:// path to the .zip
    public let inner: String        // "" = archive root, else "dir/sub"

    public init?(url: URL) {
        guard url.scheme == "archive",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let zip = comps.queryItems?.first(where: { $0.name == "zip" })?.value,
              !zip.isEmpty else { return nil }
        self.zipURL = URL(fileURLWithPath: zip)
        self.inner = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Build the `archive://` URL for a zip + inner path.
    public static func url(zip: URL, inner: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "archive"
        comps.host = ""
        comps.path = "/" + inner
        comps.queryItems = [URLQueryItem(name: "zip", value: zip.path)]
        return comps.url
    }
}

/// Read-only `FileSystemProvider` for `.zip` archives. Lists entries by shelling
/// out to `unzip -Z1` (present on macOS) — no third-party dependency — and
/// synthesizes the directory tree from the flat name list. Listing is off the
/// main actor and streamed, so a large or slow archive shows "loading…", never a
/// freeze. Write ops are unsupported (it's a browse surface); the engine still
/// copies *out* by reading through `metadata`/extraction later.
public enum ArchiveError: LocalizedError {
    case notArchive
    public var errorDescription: String? { "Not an archive location." }
}

public actor ArchiveFileSystem: FileSystemProvider {
    /// Lists raw entry paths inside a zip. Abstracted for tests (no `unzip`).
    public typealias Lister = @Sendable (URL) -> [String]
    private let lister: Lister

    /// Max entries read from one archive (audit P2-6: a crafted zip listing can't
    /// blow up memory / main-actor work).
    public static let entryCap = 100_000

    public init(lister: @escaping Lister = ArchiveFileSystem.defaultList) {
        self.lister = lister
    }

    /// Prefer the bundled 7-Zip for listing — it decodes legacy (CP866/CP1251)
    /// filename codepages to correct Unicode, where `unzip -Z1` would emit the raw
    /// bytes (Cyrillic mojibake). Fall back to `unzip` when 7-Zip isn't present.
    public static func defaultList(_ zip: URL) -> [String] {
        if ArchiveService.sevenZipAvailable {
            let l = sevenZipList(zip)
            if !l.isEmpty { return l }
        }
        return unzipList(zip)
    }

    public nonisolated func list(_ directory: URL) -> AsyncStream<ListingEvent> {
        let lister = self.lister
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                continuation.yield(.began)
                guard let loc = ArchiveLocation(url: directory) else {
                    continuation.yield(.failed("Not an archive location.")); continuation.finish(); return
                }
                // SECURITY: only browse a real, local `.zip` regular file — refuse
                // a crafted `archive://?zip=` pointing at an arbitrary path, and
                // reject `..`/NUL in the inner path (audit P1-2).
                let zp = loc.zipURL.path
                var isDir: ObjCBool = false
                guard loc.zipURL.pathExtension.lowercased() == "zip",
                      !zp.contains("\0"), !loc.inner.contains(".."),
                      FileManager.default.fileExists(atPath: zp, isDirectory: &isDir), !isDir.boolValue else {
                    continuation.yield(.failed("Not a valid .zip archive.")); continuation.finish(); return
                }
                let all = Array(lister(loc.zipURL).prefix(Self.entryCap))   // cap (audit P2-6)
                if all.isEmpty {
                    // Empty list could be a damaged/unreadable zip — say so.
                    if !FileManager.default.fileExists(atPath: loc.zipURL.path) {
                        continuation.yield(.failed("Archive not found: \(loc.zipURL.lastPathComponent)"))
                    } else {
                        continuation.yield(.finished)
                    }
                    continuation.finish(); return
                }
                let entries = Self.entries(in: all, inner: loc.inner, zip: loc.zipURL)
                if !entries.isEmpty { continuation.yield(.entries(entries)) }
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func metadata(of url: URL) async throws -> FSEntry {
        guard let loc = ArchiveLocation(url: url) else { throw ArchiveError.notArchive }
        let isDir = loc.inner.isEmpty || loc.inner.hasSuffix("/")
        return FSEntry(url: url, name: (loc.inner as NSString).lastPathComponent,
                       isDirectory: isDir, isHidden: false, size: nil, modified: nil)
    }

    public func detail(of url: URL) async -> FSDetail { FSDetail(created: nil, permissions: "r--r--r--") }
    public func directorySize(of url: URL) async -> Int64 { 0 }

    // MARK: Tree synthesis (pure, tested)

    /// Build the FSEntry rows directly under `inner` from a flat zip name list.
    /// Names a level deeper synthesize their intermediate directory once.
    public static func entries(in names: [String], inner: String, zip: URL) -> [FSEntry] {
        let prefix = inner.isEmpty ? "" : inner + "/"
        var dirs = Set<String>()
        var files = [String]()
        for raw in names {
            let name = raw.hasPrefix("./") ? String(raw.dropFirst(2)) : raw
            guard name.hasPrefix(prefix), name != prefix else { continue }
            let remainder = String(name.dropFirst(prefix.count))
            if remainder.isEmpty { continue }
            if let slash = remainder.firstIndex(of: "/") {
                let dir = String(remainder[remainder.startIndex..<slash])
                if dir != "." && dir != ".." { dirs.insert(dir) }
            } else if !remainder.isEmpty && remainder != "." && remainder != ".." {
                files.append(remainder)
            }
        }
        var out: [FSEntry] = []
        for d in dirs.sorted() {
            let childInner = prefix + d
            if let u = ArchiveLocation.url(zip: zip, inner: childInner + "/") {
                out.append(FSEntry(url: u, name: d, isDirectory: true, isHidden: d.hasPrefix("."),
                                   size: nil, modified: nil))
            }
        }
        for f in files.sorted() {
            if let u = ArchiveLocation.url(zip: zip, inner: prefix + f) {
                out.append(FSEntry(url: u, name: f, isDirectory: false, isHidden: f.hasPrefix("."),
                                   size: nil, modified: nil))
            }
        }
        return out
    }

    /// List entry paths via `7zz l -slt` (UTF-8 names, correct for legacy
    /// codepages). Parses the `-slt` blocks after the `----------` separator;
    /// folder entries get a trailing `/` so the tree synthesis treats them as dirs.
    public static func sevenZipList(_ zip: URL) -> [String] {
        guard let z = ArchiveService.sevenZipPath else { return [] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: z)
        proc.arguments = ["l", "-slt", "-ba", zip.path]
        proc.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return [] }

        var names: [String] = []
        var curPath: String?
        var curFolder = false
        func flush() {
            guard let p = curPath, !p.isEmpty else { return }
            names.append(curFolder && !p.hasSuffix("/") ? p + "/" : p)
        }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("Path = ") {
                flush()
                curPath = String(line.dropFirst("Path = ".count)); curFolder = false
            } else if line.hasPrefix("Folder = ") {
                curFolder = line.dropFirst("Folder = ".count).trimmingCharacters(in: .whitespaces) == "+"
            }
        }
        flush()
        return names
    }

    /// Fallback lister: `unzip -Z1 <zip>` → one entry path per line. Names ride in
    /// the zip's stored encoding, so legacy non-UTF-8 zips can show mojibake — hence
    /// 7-Zip is preferred when available.
    public static func unzipList(_ zip: URL) -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-Z1", zip.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
