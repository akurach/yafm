import Foundation

// MARK: - Domain model

/// A single filesystem entry. Value type, cheap to diff for SwiftUI.
public struct FSEntry: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isHidden: Bool
    public let size: Int64?
    public let modified: Date?
    /// Populated lazily by a tag service; empty until then.
    public var tags: [Tag]

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        isHidden: Bool,
        size: Int64?,
        modified: Date?,
        tags: [Tag] = []
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isHidden = isHidden
        self.size = size
        self.modified = modified
        self.tags = tags
    }
}

/// A macOS-compatible tag. v0.1 mirrors native Finder tags (xattr).
public struct Tag: Hashable, Sendable {
    public let name: String
    /// Native macOS tag color index (0...7); nil = no color.
    public let colorIndex: Int?

    public init(name: String, colorIndex: Int? = nil) {
        self.name = name
        self.colorIndex = colorIndex
    }
}

// MARK: - Loading state (the "never freeze silently" contract)

/// What a pane shows. The UI renders every case explicitly — there is no
/// "empty" that secretly means "still loading".
public enum ListingState: Sendable {
    case idle
    case loading(partial: [FSEntry])   // spinner + already-known entries
    case loaded([FSEntry])
    case failed(String)                // human-readable message
}

/// Streamed listing events. Entries arrive incrementally so a slow/external
/// disk shows a growing list instead of a dead empty folder.
public enum ListingEvent: Sendable {
    case began
    case entries([FSEntry])
    case finished
    case failed(String)
}

// MARK: - Provider abstraction

/// Extended, on-demand metadata for the inspector. Kept off `FSEntry` (the
/// listing row) so a directory listing doesn't pay for creation-date /
/// permission / recursive-size reads on every entry.
public struct FSDetail: Sendable {
    public let created: Date?
    public let permissions: String     // "rwxr-xr-x"-style, "—" if unknown
    public init(created: Date?, permissions: String) {
        self.created = created
        self.permissions = permissions
    }
}

/// Pluggable filesystem. `LocalFileSystem` now; FTP/SMB/cloud later behind the
/// same protocol (as virtual filesystems / plugins).
///
/// All metadata reads (including the inspector's detail/size) go through the
/// provider so a virtual FS (FTP/SMB) returns correct values instead of the UI
/// reaching past it to `FileManager` and getting 0/throwing.
public protocol FileSystemProvider: Sendable {
    func list(_ directory: URL) -> AsyncStream<ListingEvent>
    func metadata(of url: URL) async throws -> FSEntry
    /// Creation date + POSIX permissions for the inspector.
    func detail(of url: URL) async -> FSDetail
    /// Recursive sum of regular-file bytes beneath a directory.
    func directorySize(of url: URL) async -> Int64
}

// MARK: - Local implementation

public actor LocalFileSystem: FileSystemProvider {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey,
    ]
    // PERF: hoisted so `entry(for:)` doesn't rebuild a Set per file (perf P1-A).
    private static let keySet = Set(keys)
    private static let batchSize = 128

    public init() {}

    public nonisolated func list(_ directory: URL) -> AsyncStream<ListingEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                continuation.yield(.began)
                let fm = FileManager.default
                // Shallow, lazy enumeration → entries stream in instead of
                // blocking until the whole directory is read.
                guard let enumerator = fm.enumerator(
                    at: directory,
                    includingPropertiesForKeys: Self.keys,
                    options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
                ) else {
                    // Surface why (permissions, missing) rather than a bare path.
                    let reason = Self.unreadableReason(directory)
                    continuation.yield(.failed("Cannot read \(directory.path(percentEncoded: false)): \(reason)"))
                    continuation.finish()
                    return
                }

                var batch: [FSEntry] = []
                batch.reserveCapacity(Self.batchSize)
                while let url = enumerator.nextObject() as? URL {
                    if Task.isCancelled { break }
                    batch.append(Self.entry(for: url))
                    if batch.count >= Self.batchSize {
                        continuation.yield(.entries(batch))
                        batch.removeAll(keepingCapacity: true)
                    }
                }
                // Cancelled mid-listing: finish without `.finished` so the
                // consumer never shows a truncated listing as complete.
                if Task.isCancelled { continuation.finish(); return }
                if !batch.isEmpty { continuation.yield(.entries(batch)) }
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func metadata(of url: URL) async throws -> FSEntry {
        Self.entry(for: url)
    }

    public func detail(of url: URL) async -> FSDetail {
        await Task.detached(priority: .userInitiated) {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            return FSDetail(created: created, permissions: Self.permissionString(url))
        }.value
    }

    public func directorySize(of url: URL) async -> Int64 {
        await Task.detached(priority: .utility) {
            var total: Int64 = 0
            let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
            if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
                while let f = en.nextObject() as? URL {
                    if Task.isCancelled { break }
                    if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                        total += Int64(v.fileSize ?? 0)
                    }
                }
            }
            return total
        }.value
    }

    /// Why a directory couldn't be enumerated — best-effort, with errno when the
    /// path can't even be stat'd.
    private static func unreadableReason(_ url: URL) -> String {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) {
            return "no such folder (errno \(errno))"
        }
        if !isDir.boolValue { return "not a folder" }
        if !fm.isReadableFile(atPath: url.path(percentEncoded: false)) { return "permission denied" }
        return "unavailable"
    }

    /// "rwxr-xr-x"-style POSIX permission string, "—" if unreadable.
    static func permissionString(_ url: URL) -> String {
        guard let n = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.posixPermissions] as? NSNumber
        else { return "—" }
        let p = n.intValue
        func rwx(_ b: Int) -> String {
            "\(b & 4 != 0 ? "r" : "-")\(b & 2 != 0 ? "w" : "-")\(b & 1 != 0 ? "x" : "-")"
        }
        return rwx((p >> 6) & 7) + rwx((p >> 3) & 7) + rwx(p & 7)
    }

    private static func entry(for url: URL) -> FSEntry {
        let v = try? url.resourceValues(forKeys: keySet)
        return FSEntry(
            url: url,
            name: url.lastPathComponent,
            isDirectory: v?.isDirectory ?? false,
            isHidden: v?.isHidden ?? false,
            size: v?.fileSize.map(Int64.init),
            modified: v?.contentModificationDate
        )
    }
}
