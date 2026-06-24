import Foundation
import XCTest
@testable import Core

/// Round-trips the v0.9.8 archive write path through the real system tools
/// (`ditto`, `zip`, `tar`) — the same binaries the app shells out to.
final class ArchiveServiceTests: XCTestCase {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yafm-arc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCompressThenExtractRoundTrips() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("hello.txt")
        try "yafm".write(to: file, atomically: true, encoding: .utf8)

        let service = ArchiveService()
        let zip = dir.appendingPathComponent("out.zip")
        try await service.compress([file], to: zip)
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path), "zip created")

        let extracted = try await service.extract(zip)
        // ditto --keepParent stores hello.txt at the archive root.
        let recovered = extracted.appendingPathComponent("hello.txt")
        XCTAssertEqual(try? String(contentsOf: recovered, encoding: .utf8), "yafm")
    }

    func testExtractRefusesUnsupportedFormat() async throws {
        XCTAssertFalse(ArchiveService.canExtract(URL(fileURLWithPath: "/tmp/foo.rar")))
        XCTAssertTrue(ArchiveService.canExtract(URL(fileURLWithPath: "/tmp/foo.zip")))
        XCTAssertTrue(ArchiveService.canExtract(URL(fileURLWithPath: "/tmp/foo.tar.gz")))

        let service = ArchiveService()
        do {
            _ = try await service.extract(URL(fileURLWithPath: "/tmp/foo.rar"))
            XCTFail("expected unsupported error")
        } catch ArchiveService.ArchiveError.unsupported {
            // expected
        }
    }
}
