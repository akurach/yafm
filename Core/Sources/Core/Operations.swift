import Foundation

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

/// One queued unit of work. `destination` is the target *directory* for
/// copy/move, the parent for rename, and nil for delete.
public struct OperationTask: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let kind: FileOperationKind
    public let sources: [URL]
    public let destination: URL?

    public init(id: UUID = UUID(), kind: FileOperationKind, sources: [URL], destination: URL? = nil) {
        self.id = id
        self.kind = kind
        self.sources = sources
        self.destination = destination
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
public actor FileEngine {
    private var cancelled: Set<UUID> = []

    public init() {}

    public func cancel(_ id: UUID) {
        cancelled.insert(id)
    }

    /// Run a task, emitting progress. The stream finishes after a terminal
    /// state (`done` / `failed` / `cancelled`).
    public nonisolated func run(_ task: OperationTask) -> AsyncStream<OperationProgress> {
        AsyncStream { continuation in
            let work = Task.detached { [self] in
                await self.execute(task, emit: { continuation.yield($0) })
                continuation.finish()
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { work.cancel() }
            }
        }
    }

    private func isCancelled(_ id: UUID) -> Bool {
        cancelled.contains(id) || Task.isCancelled
    }

    private func execute(_ task: OperationTask, emit: @Sendable (OperationProgress) -> Void) {
        defer { cancelled.remove(task.id) }   // don't let the cancel set grow forever
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
                    try FileManager.default.removeItem(at: source)
                    done += Self.size(of: source)
                    progress(source, .running)
                case .rename(let newName):
                    let dst = source.deletingLastPathComponent().appendingPathComponent(newName)
                    try FileManager.default.moveItem(at: source, to: dst)
                    done += Self.size(of: source)
                    progress(dst, .running)
                case .move:
                    guard let dir = task.destination else { throw OpError.noDestination }
                    let dst = Self.uniqueDestination(for: source, in: dir)
                    try FileManager.default.moveItem(at: source, to: dst)
                    done += Self.size(of: source)
                    progress(dst, .running)
                case .copy:
                    guard let dir = task.destination else { throw OpError.noDestination }
                    let dst = Self.uniqueDestination(for: source, in: dir)
                    try copy(source, to: dst, taskID: task.id, done: &done, total: total, emit: emit)
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
    private func copy(
        _ source: URL, to dst: URL, taskID: UUID,
        done: inout Int64, total: Int64, emit: @Sendable (OperationProgress) -> Void
    ) throws {
        let fm = FileManager.default

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

        // Refuse to clobber: the planned dst is unique, but guard the window
        // between planning and writing.
        guard !fm.fileExists(atPath: dst.path) else { throw OpError.cannotWrite }
        guard let input = InputStream(url: source) else { throw OpError.missingSource }
        guard let output = OutputStream(url: dst, append: false) else { throw OpError.cannotWrite }
        input.open(); output.open()
        defer { input.close(); output.close() }

        let bufSize = 1 << 20  // 1 MiB
        var buffer = [UInt8](repeating: 0, count: bufSize)
        while input.hasBytesAvailable {
            if isCancelled(taskID) { throw CancellationError() }
            let read = input.read(&buffer, maxLength: bufSize)
            if read < 0 { throw input.streamError ?? OpError.readFailed }
            if read == 0 { break }
            try buffer.withUnsafeBytes { raw in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!
                var offset = 0
                while offset < read {
                    let written = output.write(base + offset, maxLength: read - offset)
                    if written <= 0 || written > read - offset { throw output.streamError ?? OpError.cannotWrite }
                    offset += written
                }
            }
            done += Int64(read)
            emit(OperationProgress(id: taskID, completedBytes: done, totalBytes: total, currentFile: dst, state: .running))
        }
    }

    // MARK: Helpers

    enum OpError: LocalizedError {
        case noDestination, missingSource, cannotWrite, readFailed
        var errorDescription: String? {
            switch self {
            case .noDestination: return "No destination folder."
            case .missingSource: return "Source no longer exists."
            case .cannotWrite: return "Can't write to destination."
            case .readFailed: return "Read failed."
            }
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
        guard case .copy = kind else { return urls.reduce(0) { $0 + size(of: $1) } }
        var total: Int64 = 0
        let fm = FileManager.default
        for url in urls {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if v?.isDirectory == true {
                // Sum only file bytes; directory entries aren't payload.
                if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) {
                    for case let f as URL in e {
                        if (try? f.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false { total += size(of: f) }
                    }
                }
            } else {
                total += size(of: url)
            }
        }
        return total
    }
}
