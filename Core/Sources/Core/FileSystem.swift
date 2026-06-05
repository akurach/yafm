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

/// Pluggable filesystem. `LocalFileSystem` now; FTP/SMB/cloud later behind the
/// same protocol (as virtual filesystems / plugins).
public protocol FileSystemProvider: Sendable {
    func list(_ directory: URL) -> AsyncStream<ListingEvent>
    func metadata(of url: URL) async throws -> FSEntry
}

// MARK: - Local implementation

public actor LocalFileSystem: FileSystemProvider {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey,
    ]
    private static let batchSize = 128

    public init() {}

    public nonisolated func list(_ directory: URL) -> AsyncStream<ListingEvent> {
        AsyncStream { continuation in
            let task = Task.detached {
                continuation.yield(.began)
                let fm = FileManager.default
                // Shallow, lazy enumeration → entries stream in instead of
                // blocking until the whole directory is read.
                guard let enumerator = fm.enumerator(
                    at: directory,
                    includingPropertiesForKeys: Self.keys,
                    options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
                ) else {
                    continuation.yield(.failed("Cannot read \(directory.path)"))
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

    private static func entry(for url: URL) -> FSEntry {
        let v = try? url.resourceValues(forKeys: Set(keys))
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
