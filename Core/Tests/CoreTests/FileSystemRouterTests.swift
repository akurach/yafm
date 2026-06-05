import Foundation
import XCTest
@testable import Core

final class FileSystemRouterTests: XCTestCase {

    /// A stub provider that flags when it's been hit and yields one named entry.
    private struct StubProvider: FileSystemProvider {
        let marker: String
        nonisolated func list(_ directory: URL) -> AsyncStream<ListingEvent> {
            AsyncStream { c in
                c.yield(.entries([FSEntry(url: directory.appendingPathComponent(marker),
                                          name: marker, isDirectory: false, isHidden: false,
                                          size: nil, modified: nil)]))
                c.yield(.finished); c.finish()
            }
        }
        func metadata(of url: URL) async throws -> FSEntry {
            FSEntry(url: url, name: marker, isDirectory: false, isHidden: false, size: nil, modified: nil)
        }
        func detail(of url: URL) async -> FSDetail { FSDetail(created: nil, permissions: marker) }
        func directorySize(of url: URL) async -> Int64 { 0 }
    }

    /// A `file://` URL routes to the local provider and lists for real.
    func testFileURLRoutesToLocal() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yafm-router-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "x".write(to: tmp.appendingPathComponent("real.txt"), atomically: true, encoding: .utf8)

        let router = FileSystemRouter()
        var names: Set<String> = []
        for await e in router.list(tmp) { if case .entries(let b) = e { names.formUnion(b.map(\.name)) } }
        XCTAssertEqual(names, ["real.txt"])
    }

    /// A registered scheme routes to that provider, not local.
    func testRegisteredSchemeRoutesToProvider() async throws {
        let router = FileSystemRouter().registering(StubProvider(marker: "SMB"), for: "smb")
        let url = URL(string: "smb://server/share")!
        var names: [String] = []
        for await e in router.list(url) { if case .entries(let b) = e { names += b.map(\.name) } }
        XCTAssertEqual(names, ["SMB"])
        let detail = await router.detail(of: url)
        XCTAssertEqual(detail.permissions, "SMB")
    }

    /// An unregistered scheme falls back to local rather than failing.
    func testUnknownSchemeFallsBackToLocal() {
        let router = FileSystemRouter().registering(StubProvider(marker: "SMB"), for: "smb")
        let ftp = URL(string: "ftp://host/path")!
        // provider(for:) is the routing decision; unknown scheme → the local default.
        XCTAssertFalse(router.provider(for: ftp) is StubProvider)
    }
}
