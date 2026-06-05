import Foundation

/// Routes filesystem calls to a provider chosen by the URL scheme.
///
/// The seam for virtual filesystems (v0.7 SMB/FTP, v0.8 archives): today every
/// URL is `file://` and falls to `local`, so the app behaves exactly as before.
/// When an SMB provider arrives it registers under `"smb"` and the call sites
/// — `TabModel`/`PaneModel`/`AppState`, which only know `FileSystemProvider` —
/// don't change. Introduced early (one provider behind it) precisely so that
/// later addition is a registration, not a rewrite.
///
/// Immutable value type: `registering(_:for:)` returns a new router rather than
/// mutating, so it stays `Sendable` without locking and `list(_:)` can be
/// `nonisolated` (it must return the stream synchronously).
public struct FileSystemRouter: FileSystemProvider {
    private let local: FileSystemProvider
    private let providers: [String: FileSystemProvider]

    public init(local: FileSystemProvider = LocalFileSystem(),
                providers: [String: FileSystemProvider] = [:]) {
        self.local = local
        self.providers = providers
    }

    /// A new router with `provider` handling the given URL scheme (e.g. "smb").
    public func registering(_ provider: FileSystemProvider, for scheme: String) -> FileSystemRouter {
        var next = providers
        next[scheme.lowercased()] = provider
        return FileSystemRouter(local: local, providers: next)
    }

    /// The provider for a URL: by scheme, else local. `file` and scheme-less
    /// (plain path) URLs both resolve to `local`.
    public func provider(for url: URL) -> FileSystemProvider {
        guard let scheme = url.scheme?.lowercased(), scheme != "file" else { return local }
        return providers[scheme] ?? local
    }

    public nonisolated func list(_ directory: URL) -> AsyncStream<ListingEvent> {
        provider(for: directory).list(directory)
    }

    public func metadata(of url: URL) async throws -> FSEntry {
        try await provider(for: url).metadata(of: url)
    }

    public func detail(of url: URL) async -> FSDetail {
        await provider(for: url).detail(of: url)
    }

    public func directorySize(of url: URL) async -> Int64 {
        await provider(for: url).directorySize(of: url)
    }
}
