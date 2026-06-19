import Foundation
import XCTest
@testable import Core

/// Covers the v0.7 SMB virtual filesystem at the layer that's testable without a
/// live server: smb:// URL parsing, router scheme dispatch, and the provider's
/// list/error flow against a stubbed mounter (so no real mount happens).
final class SMBTests: XCTestCase {

    // MARK: smb:// URL parsing

    func testParsesHostShareAndSubpath() throws {
        let loc = try XCTUnwrap(SMBLocation(url: URL(string: "smb://nas.local/Media/Movies/2026")!))
        XCTAssertEqual(loc.shareRoot.absoluteString, "smb://nas.local/Media")
        XCTAssertEqual(loc.subpath, ["Movies", "2026"])
    }

    func testShareRootHasNoSubpath() throws {
        let loc = try XCTUnwrap(SMBLocation(url: URL(string: "smb://server/share")!))
        XCTAssertEqual(loc.subpath, [])
    }

    func testRejectsNonSMBAndHostlessURLs() {
        XCTAssertNil(SMBLocation(url: URL(string: "file:///Users")!))
        XCTAssertNil(SMBLocation(url: URL(string: "smb://")!))
        XCTAssertNil(SMBLocation(url: URL(fileURLWithPath: "/tmp")))
    }

    // MARK: Router dispatch

    func testRouterSendsSMBSchemeToSMBProvider() {
        let router = FileSystemRouter().registering(SMBFileSystem(), for: "smb")
        let smb = router.provider(for: URL(string: "smb://h/s")!)
        XCTAssertTrue(smb is SMBFileSystem)
        let local = router.provider(for: URL(fileURLWithPath: "/tmp"))
        XCTAssertFalse(local is SMBFileSystem)
    }

    // MARK: Listing through a stub mount (entries re-keyed into smb:// space)

    func testListsMountedShareAndReKeysEntries() async throws {
        // A temp dir stands in for the mounted share.
        let mount = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("smb-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mount) }
        try Data().write(to: mount.appendingPathComponent("hello.txt"))
        try FileManager.default.createDirectory(at: mount.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)

        let fs = SMBFileSystem(mounter: StubMounter(mountPoint: mount))
        let shareURL = URL(string: "smb://nas/Media")!

        var names: [String] = []
        var urls: [URL] = []
        for await event in fs.list(shareURL) {
            if case .entries(let batch) = event {
                names.append(contentsOf: batch.map(\.name))
                urls.append(contentsOf: batch.map(\.url))
            }
        }
        XCTAssertEqual(Set(names), ["hello.txt", "sub"])
        // Crucially: entry URLs are smb://, not /Volumes — navigation stays in-provider.
        XCTAssertTrue(urls.allSatisfy { $0.scheme == "smb" }, "entries must be re-keyed to smb://")
        XCTAssertTrue(urls.contains(URL(string: "smb://nas/Media/hello.txt")!))
    }

    // MARK: A stale mountpoint (share dropped) triggers a re-mount, not a dead dir

    func testStaleMountpointTriggersRemount() async throws {
        let mounter = CountingMounter()
        defer { mounter.cleanup() }
        let fs = SMBFileSystem(mounter: mounter)
        let shareURL = URL(string: "smb://nas/Media")!

        // First listing mounts once.
        for await _ in fs.list(shareURL) {}
        XCTAssertEqual(mounter.calls, 1)

        // Listing again reuses the cached mountpoint — no re-mount.
        for await _ in fs.list(shareURL) {}
        XCTAssertEqual(mounter.calls, 1, "a live mountpoint must be cached, not re-mounted")

        // Simulate the share dropping (NAS reboot / sleep): the cached path vanishes.
        mounter.removeLastMountpoint()
        for await _ in fs.list(shareURL) {}
        XCTAssertEqual(mounter.calls, 2, "a vanished mountpoint must be dropped and re-mounted")
    }

    // MARK: A failed mount becomes a visible .failed listing (never a freeze)

    func testFailedMountYieldsFailedEvent() async {
        let fs = SMBFileSystem(mounter: FailingMounter())
        var failure: String?
        for await event in fs.list(URL(string: "smb://down.host/share")!) {
            if case .failed(let m) = event { failure = m }
        }
        XCTAssertNotNil(failure)
        XCTAssertTrue(failure!.contains("down.host"), "the message should name the unreachable host")
    }
}

// MARK: - Stubs

private struct StubMounter: ShareMounter {
    let mountPoint: URL
    func mountPoint(forShareRoot shareRoot: URL) async throws -> URL { mountPoint }
}

private struct FailingMounter: ShareMounter {
    func mountPoint(forShareRoot shareRoot: URL) async throws -> URL {
        throw SMBError.mountFailed(code: 64, host: shareRoot.host ?? "server")
    }
}

/// Counts mount calls and hands back a fresh, real temp dir each time, so the
/// provider's cache-validity check (fileExists on the mountpoint) can be exercised.
private final class CountingMounter: ShareMounter, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var dirs: [URL] = []

    var calls: Int { lock.withLock { _calls } }

    func mountPoint(forShareRoot shareRoot: URL) async throws -> URL {
        lock.withLock {
            _calls += 1
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("smb-remount-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            dirs.append(dir)
            return dir
        }
    }

    /// Delete the most recently issued mountpoint — simulates the share dropping.
    func removeLastMountpoint() {
        lock.withLock { if let last = dirs.last { try? FileManager.default.removeItem(at: last) } }
    }

    func cleanup() {
        lock.withLock { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }
    }
}
