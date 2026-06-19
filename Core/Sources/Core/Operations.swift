import Foundation
import os

// MARK: - File operations (own engine: visible queue, progress, cancel)

/// What an operation does. `rename` carries the new leaf name.
public enum FileOperationKind: Sendable, Equatable {
    case copy
    case move
    case delete
    case rename(to: String)

    public var verb: String {
        switch self {
        case .copy: return "Copying"
        case .move: return "Moving"
        case .delete: return "Deleting"
        case .rename: return "Renaming"
        }
    }
}

/// How copy/move resolves an existing file at the destination.
/// `keepBoth` (default) is the historical behaviour ("file copy.txt").
public enum CollisionPolicy: String, Sendable, Equatable, CaseIterable {
    case keepBoth, skip, replace
}

/// One queued unit of work. `destination` is the target *directory* for
/// copy/move, the parent for rename, and nil for delete.
public struct OperationTask: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: FileOperationKind
    public let sources: [URL]
    public let destination: URL?
    public let collision: CollisionPolicy

    public init(id: UUID = UUID(), kind: FileOperationKind, sources: [URL],
                destination: URL? = nil, collision: CollisionPolicy = .keepBoth) {
        self.id = id
        self.kind = kind
        self.sources = sources
        self.destination = destination
        self.collision = collision
    }
}

/// Live progress for a task. Streamed, never polled.
public struct OperationProgress: Sendable, Equatable {
    public enum State: Sendable, Equatable { case running, done, failed(String), cancelled }
    public let id: UUID
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let currentFile: URL?
    public let state: State

    public init(id: UUID, completedBytes: Int64, totalBytes: Int64, currentFile: URL?, state: State) {
        self.id = id
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.currentFile = currentFile
        self.state = state
    }

    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : (state == .done ? 1 : 0)
    }
}

/// Async copy/move/delete/rename with real byte progress and cancellation.
/// Never runs on the main thread; the UI observes the streamed progress.
///
/// The cancel set lives in an `OSAllocatedUnfairLock` rather than actor-isolated
/// state: the blocking copy loop runs `nonisolated` (off any actor executor), so
/// a `cancel(_:)` from the UI is observed mid-flight instead of queueing behind
/// the in-progress `execute`. (Was the cause of B-2: cancel did nothing.)
public actor FileEngine {
    private let cancelledBox = OSAllocatedUnfairLock<Set<UUID>>(initialState: [])

    public init() {}

    public nonisolated func cancel(_ id: UUID) {
        cancelledBox.withLock { _ = $0.insert(id) }
    }

    /// Create a directory through the engine so all mutating FS work funnels
    /// through one place (no `FileManager` mkdir scattered in the UI layer).
    public nonisolated func makeDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    /// Run a task, emitting progress. The stream finishes after a terminal
    /// state (`done` / `failed` / `cancelled`).
    public nonisolated func run(_ task: OperationTask) -> AsyncStream<OperationProgress> {
        AsyncStream { continuation in
            let work = Task.detached(priority: .userInitiated) { [self] in
                self.execute(task, emit: { continuation.yield($0) })
                continuation.finish()
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { work.cancel() }
            }
        }
    }

    private nonisolated func isCancelled(_ id: UUID) -> Bool {
        cancelledBox.withLock { $0.contains(id) } || Task.isCancelled
    }

    private nonisolated func execute(_ task: OperationTask, emit: @Sendable (OperationProgress) -> Void) {
        defer { cancelledBox.withLock { _ = $0.remove(task.id) } }   // don't let the cancel set grow forever
        let total = Self.totalBytes(of: task.sources, kind: task.kind)
        var done: Int64 = 0

        func progress(_ file: URL?, _ state: OperationProgress.State) {
            emit(OperationProgress(id: task.id, completedBytes: done, totalBytes: total, currentFile: file, state: state))
        }

        progress(task.sources.first, .running)

        do {
            for source in task.sources {
                if isCancelled(task.id) { progress(source, .cancelled); return }
                switch task.kind {
                case .delete:
                    // Size BEFORE removing — afterwards the item is gone and
                    // `size(of:)` would read 0, freezing delete progress at 0%.
                    let bytes = Self.contentBytes(of: source)
                    try FileManager.default.removeItem(at: source)
                    done += bytes
                    progress(source, .running)
                case .rename(let newName):
                    // SECURITY: a leaf name only — reject path separators / NUL so
                    // a rename can't redirect into another directory (audit P2-3).
                    guard !newName.isEmpty, !newName.contains("/"), !newName.contains("\0"),
                          newName != ".", newName != ".." else { throw OpError.cannotWrite }
                    let bytes = Self.size(of: source)   // size BEFORE the move (P2-4)
                    let dst = source.deletingLastPathComponent().appendingPathComponent(newName)
                    try FileManager.default.moveItem(at: source, to: dst)
                    done += bytes
                    progress(dst, .running)
                case .move:
                    guard let dir = task.destination else { throw OpError.noDestination }
                    guard let dst = try Self.plannedDestination(for: source, in: dir, policy: task.collision) else {
                        done += Self.size(of: source); progress(source, .running); continue   // skipped
                    }
                    let bytes = Self.size(of: source)   // size BEFORE the move (P2-4)
                    try moveOrCopyDelete(source, to: dst, replacing: task.collision == .replace,
                                         taskID: task.id, bytes: bytes, done: &done, total: total, emit: emit)
                    if isCancelled(task.id) { progress(source, .cancelled); return }
                    progress(dst, .running)
                case .copy:
                    guard let dir = task.destination else { throw OpError.noDestination }
                    guard let dst = try Self.plannedDestination(for: source, in: dir, policy: task.collision) else {
                        done += Self.contentBytes(of: source); progress(source, .running); continue   // skipped
                    }
                    try copy(source, to: dst, taskID: task.id, replacing: task.collision == .replace,
                             done: &done, total: total, emit: emit)
                }
            }
            if isCancelled(task.id) { progress(nil, .cancelled); return }
            done = total
            progress(nil, .done)
        } catch is CancellationError {
            progress(nil, .cancelled)
        } catch {
            progress(nil, .failed(error.localizedDescription))
        }
    }

    /// Streamed copy so progress is real, not faked. Recurses into directories.
    private nonisolated func copy(
        _ source: URL, to dst: URL, taskID: UUID, replacing: Bool = false,
        done: inout Int64, total: Int64, emit: @Sendable (OperationProgress) -> Void
    ) throws {
        let fm = FileManager.default

        // OPS-1 atomic replace: when overwriting an existing item, copy into a
        // temp sibling first, then swap with `replaceItemAt`. A failure/cancel
        // mid-copy leaves the original intact — never both files lost.
        if replacing, fm.fileExists(atPath: dst.path) {
            let temp = dst.deletingLastPathComponent()
                .appendingPathComponent(".yafm-tmp-\(UUID().uuidString)-\(dst.lastPathComponent)")
            do {
                try copy(source, to: temp, taskID: taskID, replacing: false,
                         done: &done, total: total, emit: emit)
                _ = try fm.replaceItemAt(dst, withItemAt: temp)
            } catch {
                try? fm.removeItem(at: temp)   // don't leak a partial temp
                throw error
            }
            return
        }

        // Copy symlinks as links — never follow them. Following a symlink in a
        // copied tree would read files anywhere on disk (path traversal).
        let rv = try? source.resourceValues(forKeys: [.isSymbolicLinkKey])
        if rv?.isSymbolicLink == true {
            try fm.copyItem(at: source, to: dst)
            done += Self.size(of: source)
            return
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { throw OpError.missingSource }

        if isDir.boolValue {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            for child in children {
                if isCancelled(taskID) { throw CancellationError() }
                try copy(child, to: dst.appendingPathComponent(child.lastPathComponent),
                         taskID: taskID, done: &done, total: total, emit: emit)
            }
            return
        }

        // Create the output with O_CREAT|O_EXCL|O_NOFOLLOW: the kernel refuses if
        // anything already exists at the path (closing the TOCTOU window between a
        // `fileExists` check and the open) and won't follow a planted symlink.
        guard let input = InputStream(url: source) else { throw OpError.missingSource }
        let outFD = open(dst.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard outFD >= 0 else { throw OpError.cannotWrite }
        let output = FileHandle(fileDescriptor: outFD, closeOnDealloc: true)
        input.open()
        defer { input.close(); try? output.close() }

        let bufSize = 1 << 20  // 1 MiB
        var buffer = [UInt8](repeating: 0, count: bufSize)
        while input.hasBytesAvailable {
            if isCancelled(taskID) { throw CancellationError() }
            let read = input.read(&buffer, maxLength: bufSize)
            if read < 0 { throw input.streamError ?? OpError.readFailed }
            if read == 0 { break }
            try output.write(contentsOf: Data(buffer[0..<read]))
            done += Int64(read)
            emit(OperationProgress(id: taskID, completedBytes: done, totalBytes: total, currentFile: dst, state: .running))
        }
    }

    /// Move `source` onto `dst`. A plain `moveItem` is a fast metadata rename, but
    /// it throws across filesystems (`EXDEV` — USB sticks, network mounts, DMGs,
    /// some APFS volume boundaries) and when `dst` already exists. In those cases
    /// fall back to the streamed `copy` (atomic when replacing) + delete-source, so
    /// F6/move to another volume actually works instead of failing outright. The
    /// source is removed **only after a clean copy**; a cancel/throw mid-copy leaves
    /// it intact — the move simply didn't happen. Any non-EXDEV error propagates.
    private nonisolated func moveOrCopyDelete(
        _ source: URL, to dst: URL, replacing: Bool, taskID: UUID,
        bytes: Int64, done: inout Int64, total: Int64,
        emit: @Sendable (OperationProgress) -> Void
    ) throws {
        let fm = FileManager.default
        // Fast path: a real rename. Skipped when replacing an existing item
        // (moveItem can't overwrite) — that routes through the atomic copy below.
        if !(replacing && fm.fileExists(atPath: dst.path)) {
            do {
                try fm.moveItem(at: source, to: dst)
                done += bytes
                return
            } catch {
                guard Self.isCrossDevice(error) else { throw error }
                // EXDEV → fall through to copy + delete.
            }
        }
        try copy(source, to: dst, taskID: taskID, replacing: replacing,
                 done: &done, total: total, emit: emit)
        if isCancelled(taskID) { return }   // caller emits .cancelled; source kept
        try fm.removeItem(at: source)
    }

    /// True when `error` (or its underlying error) is POSIX `EXDEV` — a
    /// cross-device link, i.e. `moveItem` can't rename across filesystems.
    /// `FileManager` wraps the POSIX failure in an `NSCocoaErrorDomain` error with
    /// the real `EXDEV` carried under `NSUnderlyingErrorKey`.
    static func isCrossDevice(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(EXDEV) { return true }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           u.domain == NSPOSIXErrorDomain && u.code == Int(EXDEV) { return true }
        return false
    }

    // MARK: Helpers

    public enum OpError: LocalizedError {
        case noDestination, missingSource, cannotWrite, readFailed
        public var errorDescription: String? {
            switch self {
            case .noDestination: return "No destination folder."
            case .missingSource: return "Source no longer exists."
            case .cannotWrite: return "Can't write to destination."
            case .readFailed: return "Read failed."
            }
        }
    }

    /// Resolve the destination per collision policy. Returns nil to signal
    /// "skip this source". `replace` returns the live path **without** deleting —
    /// the copy writes to a temp sibling and swaps atomically (OPS-1), so a
    /// failed/cancelled replace can't destroy the existing file.
    static func plannedDestination(for source: URL, in dir: URL, policy: CollisionPolicy) throws -> URL? {
        let fm = FileManager.default
        switch policy {
        case .keepBoth:
            return uniqueDestination(for: source, in: dir)
        case .skip:
            let dst = dir.appendingPathComponent(source.lastPathComponent)
            return fm.fileExists(atPath: dst.path) ? nil : dst
        case .replace:
            return dir.appendingPathComponent(source.lastPathComponent)
        }
    }

    /// Pick a non-colliding destination ("file copy.txt", "file copy 2.txt").
    static func uniqueDestination(for source: URL, in dir: URL) -> URL {
        let fm = FileManager.default
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = dir.appendingPathComponent(source.lastPathComponent)
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            n += 1
            let suffix = n == 2 ? " copy" : " copy \(n)"
            let name = ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)"
            candidate = dir.appendingPathComponent(name)
        }
        return candidate
    }

    static func size(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
    }

    static func totalBytes(of urls: [URL], kind: FileOperationKind) -> Int64 {
        switch kind {
        case .copy, .delete:
            // Recurse so a folder's progress reflects its contents, not a single
            // directory-entry size (M-10: delete of a folder jumped 0→100%).
            return urls.reduce(0) { $0 + contentBytes(of: $1) }
        case .move, .rename:
            // Move/rename are metadata ops; shallow size is enough.
            return urls.reduce(0) { $0 + size(of: $1) }
        }
    }

    /// Total payload bytes of `url`: its own size, or the sum of regular-file
    /// bytes beneath it if it's a directory.
    static func contentBytes(of url: URL) -> Int64 {
        let fm = FileManager.default
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard v?.isDirectory == true else { return size(of: url) }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) {
            for case let f as URL in e {
                if (try? f.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false { total += size(of: f) }
            }
        }
        return total
    }
}
