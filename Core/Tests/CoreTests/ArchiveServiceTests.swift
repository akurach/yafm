import Foundation
import XCTest
@testable import Core

/// Round-trips the v0.9.8 archive write path through the real system tools
/// (`ditto`, `zip`, `tar`, `gzip`) — the same binaries the app shells out to.
final class ArchiveServiceTests: XCTestCase {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yafm-arc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seedFile(in dir: URL, name: String = "hello.txt", body: String = "yafm") throws -> URL {
        let f = dir.appendingPathComponent(name)
        try body.write(to: f, atomically: true, encoding: .utf8)
        return f
    }

    func testZipRoundTrip() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try seedFile(in: dir)
        let service = ArchiveService()
        let zip = dir.appendingPathComponent("out.zip")
        try await service.compress([file], to: zip, format: .zip)
        let extracted = try await service.extract(zip)
        XCTAssertEqual(try? String(contentsOf: extracted.appendingPathComponent("hello.txt"), encoding: .utf8), "yafm")
    }

    func testTarGzRoundTrip() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try seedFile(in: dir, name: "a.txt", body: "data")
        let service = ArchiveService()
        let arc = dir.appendingPathComponent("out.tar.gz")
        try await service.compress([file], to: arc, format: .tarGz, level: 9)
        let extracted = try await service.extract(arc)
        XCTAssertEqual(try? String(contentsOf: extracted.appendingPathComponent("a.txt"), encoding: .utf8), "data")
    }

    func testPasswordZipNeedsPasswordThenExtracts() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try seedFile(in: dir, name: "secret.txt", body: "classified")
        let service = ArchiveService()
        let zip = dir.appendingPathComponent("locked.zip")
        try await service.compress([file], to: zip, format: .zip, password: "hunter2")

        // No password → must report it's protected, not hang or half-extract.
        do {
            _ = try await service.extract(zip)
            XCTFail("expected needsPassword")
        } catch ArchiveService.ArchiveError.needsPassword { /* expected */ }

        // Wrong password → wrongPassword.
        do {
            _ = try await service.extract(zip, password: "nope")
            XCTFail("expected wrongPassword")
        } catch ArchiveService.ArchiveError.wrongPassword { /* expected */ }

        // Right password → contents recovered.
        let extracted = try await service.extract(zip, password: "hunter2")
        XCTAssertEqual(try? String(contentsOf: extracted.appendingPathComponent("secret.txt"), encoding: .utf8), "classified")
    }

    func testCanExtractRecognizesFormats() {
        XCTAssertTrue(ArchiveService.canExtract(URL(fileURLWithPath: "/t/a.zip")))
        XCTAssertTrue(ArchiveService.canExtract(URL(fileURLWithPath: "/t/a.7z")))
        XCTAssertTrue(ArchiveService.canExtract(URL(fileURLWithPath: "/t/a.rar")))
        XCTAssertTrue(ArchiveService.canExtract(URL(fileURLWithPath: "/t/a.tar.xz")))
        XCTAssertTrue(ArchiveService.canExtract(URL(fileURLWithPath: "/t/a.tgz")))
        XCTAssertFalse(ArchiveService.canExtract(URL(fileURLWithPath: "/t/a.txt")))
    }

    func testFormatMetadata() {
        XCTAssertTrue(ArchiveService.CompressionFormat.zip.supportsPassword)
        XCTAssertFalse(ArchiveService.CompressionFormat.tarGz.supportsPassword)
        XCTAssertTrue(ArchiveService.CompressionFormat.tarGz.supportsLevel)
        XCTAssertFalse(ArchiveService.CompressionFormat.tarBz2.supportsLevel)
        XCTAssertEqual(ArchiveService.CompressionFormat.tarXz.fileExtension, "tar.xz")
    }
}
