import Foundation
import NetFS

// MARK: - SMB as a virtual filesystem (v0.7)

/// Where an `smb://` URL points: the share root (`smb://host/share`) plus the
/// path components beneath it. The share root is the mount unit; the subpath is
/// resolved against the local mountpoint once mounted.
public struct SMBLocation: Equatable, Sendable {
    public let shareRoot: URL          // smb://host/share
    public let subpath: [String]       // ["sub", "dir"] under the share

    /// Parse a full `smb://` URL. nil for anything that isn't `smb` or lacks a
    /// host + share. Credentials embedded in the URL are preserved on the share
    /// root so the mounter can use them (then they live only in the Keychain).
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "smb",
              let host = url.host, !host.isEmpty else { return nil }
        // pathComponents drops the leading "/"; first real component = share.
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let share = parts.first else { return nil }
        self.subpath = Array(parts.dropFirst())

        var comps = URLComponents()
        comps.scheme = "smb"
        comps.host = host
        comps.port = url.port
        comps.user = url.user
        comps.password = url.password
        comps.path = "/" + share
        guard let root = comps.url else { return nil }
        self.shareRoot = root
    }
}

/// Mounts an SMB share and reports its local mountpoint. Abstracted so the
/// provider is unit-testable with a stub (no live server / no real mount).
public protocol ShareMounter: Sendable {
    /// Ensure `shareRoot` (smb://host/share) is mounted; return its local
    /// mountpoint (a `file://` URL, e.g. `/Volumes/share`). Throws on failure.
    func mountPoint(forShareRoot shareRoot: URL) async throws -> URL
}

/// Errors surfaced to the unified state-view as a `.failed` listing — a remote
/// disk that won't connect is a *visible* dead-end, never a frozen pane.
public enum SMBError: LocalizedError, Equatable {
    case notSMB
    case mountFailed(code: Int32, host: String)
    case noMountPoint

    public var errorDescription: String? {
        switch self {
        case .notSMB: return "Not an SMB location."
        case .mountFailed(let code, let host):
            return "Couldn't connect to \(host) (error \(code)). Check the address, your network, and credentials."
        case .noMountPoint: return "The share mounted but reported no location."
        }
    }
}

/// `FileSystemProvider` for `smb://`. It mounts the share natively (NetFS — the
/// system handles the SMB protocol, Keychain credentials, and the connection UI)
/// and then delegates listing/metadata to a `LocalFileSystem` over the
/// mountpoint. The mount runs off the main actor and the listing streams, so a
/// hung or slow share shows "loading…" / a `.failed` message — it can never
/// freeze the app. This is the v0.4 router's first non-local provider; call
/// sites that only know `FileSystemProvider` are unchanged.
public actor SMBFileSystem: FileSystemProvider {
    private let mounter: ShareMounter
    private let local: LocalFileSystem
    /// Cache resolved mountpoints by share root so repeated navigation in a
    /// share doesn't re-mount.
    private var mountpoints: [URL: URL] = [:]

    public init(mounter: ShareMounter = NetFSShareMounter(), local: LocalFileSystem = LocalFileSystem()) {
        self.mounter = mounter
        self.local = local
    }

    /// Resolve an `smb://` URL to its local mounted URL, mounting on demand.
    private func localURL(for url: URL) async throws -> URL {
        guard let loc = SMBLocation(url: url) else { throw SMBError.notSMB }
        let mp: URL
        // Trust the cache only while the mountpoint still exists. A share that
        // dropped (laptop slept, NAS rebooted, user unmounted) leaves a stale
        // /Volumes path that would list as a dead local dir forever — drop it and
        // re-mount instead.
        if let cached = mountpoints[loc.shareRoot], FileManager.default.fileExists(atPath: cached.path) {
            mp = cached
        } else {
            mountpoints[loc.shareRoot] = nil
            mp = try await mounter.mountPoint(forShareRoot: loc.shareRoot)
            mountpoints[loc.shareRoot] = mp
        }
        return loc.subpath.reduce(mp) { $0.appendingPathComponent($1) }
    }

    public nonisolated func list(_ directory: URL) -> AsyncStream<ListingEvent> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.began)
                do {
                    let localDir = try await self.localURL(for: directory)
                    // Delegate to the local provider over the mountpoint, but
                    // re-key each entry from its /Volumes URL back into smb://
                    // space so navigating stays inside this provider.
                    for await event in await self.local.list(localDir) {
                        if case .entries(let batch) = event {
                            continuation.yield(.entries(batch.map { Self.rekey($0, under: directory) }))
                        } else {
                            continuation.yield(event)
                        }
                    }
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    continuation.yield(.failed(message))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func metadata(of url: URL) async throws -> FSEntry {
        let entry = try await local.metadata(of: localURL(for: url))
        // Re-key to the smb:// URL so the UI navigates in SMB space, not into
        // /Volumes (which would escape the provider).
        return FSEntry(url: url, name: entry.name, isDirectory: entry.isDirectory,
                       isHidden: entry.isHidden, size: entry.size, modified: entry.modified,
                       tags: entry.tags)
    }

    /// Replace an entry's local /Volumes URL with `parent/<name>` in smb:// space.
    private static func rekey(_ entry: FSEntry, under parent: URL) -> FSEntry {
        FSEntry(url: parent.appendingPathComponent(entry.name), name: entry.name,
                isDirectory: entry.isDirectory, isHidden: entry.isHidden,
                size: entry.size, modified: entry.modified, tags: entry.tags)
    }

    public func detail(of url: URL) async -> FSDetail {
        guard let local = try? await localURL(for: url) else {
            return FSDetail(created: nil, permissions: "—")
        }
        return await self.local.detail(of: local)
    }

    public func directorySize(of url: URL) async -> Int64 {
        guard let local = try? await localURL(for: url) else { return 0 }
        return await self.local.directorySize(of: local)
    }
}

// MARK: - NetFS-backed mounter (the real one)

/// Mounts via `NetFSMountURLSync` on a background thread. The system presents
/// its own auth UI when needed and stores credentials in the Keychain — yafm
/// never holds a plaintext password. Treated as the trust boundary: we pass the
/// URL the user typed and let the OS do the protocol + security.
public struct NetFSShareMounter: ShareMounter {
    /// Give up waiting on a mount after this long. `NetFSMountURLSync` blocks on a
    /// firewalled/packet-dropping host for the system's full TCP timeout (30–75s),
    /// which reads as "loading…" forever. We can't interrupt the C call (it leaks
    /// the background thread until the OS gives up), but surfacing a timeout turns
    /// an endless spinner into an honest "couldn't connect" dead-end.
    public static let timeoutSeconds: Double = 20

    public init() {}

    public func mountPoint(forShareRoot shareRoot: URL) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { try await Self.mount(shareRoot) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
                throw SMBError.mountFailed(code: ETIMEDOUT, host: shareRoot.host ?? "server")
            }
            defer { group.cancelAll() }            // whoever lost the race is cancelled
            return try await group.next()!         // first result (or first throw) wins
        }
    }

    /// The blocking NetFS mount, off the main actor. The system presents its own
    /// auth UI when needed and stores credentials in the Keychain — yafm never
    /// holds a plaintext password.
    private static func mount(_ shareRoot: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var mountpoints: Unmanaged<CFArray>?
                // open_options / mount_options nil → system defaults + Keychain.
                let status = NetFSMountURLSync(
                    shareRoot as CFURL, nil, nil, nil, nil, nil, &mountpoints
                )
                guard status == 0 else {
                    continuation.resume(throwing: SMBError.mountFailed(
                        code: status, host: shareRoot.host ?? "server"))
                    return
                }
                guard let array = mountpoints?.takeRetainedValue() as? [String],
                      let first = array.first else {
                    continuation.resume(throwing: SMBError.noMountPoint)
                    return
                }
                continuation.resume(returning: URL(fileURLWithPath: first))
            }
        }
    }
}
