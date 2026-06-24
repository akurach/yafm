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
        try await service.compress([file], to: zip, options: .init(format: .zip))
        // A single-entry archive is unwrapped — extract returns the file itself
        // (collision-suffixed here, since the original hello.txt sits beside it).
        let extracted = try await service.extract(zip)
        XCTAssertTrue(extracted.lastPathComponent.hasPrefix("hello"))
        XCTAssertEqual(try? String(contentsOf: extracted, encoding: .utf8), "yafm")
    }

    func testTarGzRoundTrip() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try seedFile(in: dir, name: "a.txt", body: "data")
        let service = ArchiveService()
        let arc = dir.appendingPathComponent("out.tar.gz")
        try await service.compress([file], to: arc, options: .init(format: .tarGz, level: 9))
        let extracted = try await service.extract(arc)
        XCTAssertEqual(try? String(contentsOf: extracted, encoding: .utf8), "data")
    }

    func testPasswordZipNeedsPasswordThenExtracts() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try seedFile(in: dir, name: "secret.txt", body: "classified")
        let service = ArchiveService()
        let zip = dir.appendingPathComponent("locked.zip")
        try await service.compress([file], to: zip, options: .init(format: .zip, password: "hunter2"))

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
        XCTAssertEqual(try? String(contentsOf: extracted, encoding: .utf8), "classified")
    }

    func testMultiFileKeepsWrapFolder() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try seedFile(in: dir, name: "a.txt", body: "A")
        let b = try seedFile(in: dir, name: "b.txt", body: "B")
        let service = ArchiveService()
        let zip = dir.appendingPathComponent("multi.zip")
        try await service.compress([a, b], to: zip, options: .init(format: .zip))
        // Two entries → the wrap folder is kept and holds both.
        let extracted = try await service.extract(zip)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(try? String(contentsOf: extracted.appendingPathComponent("a.txt"), encoding: .utf8), "A")
        XCTAssertEqual(try? String(contentsOf: extracted.appendingPathComponent("b.txt"), encoding: .utf8), "B")
    }

    func testExcludeHiddenSkipsDotfiles() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "keep".write(to: folder.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appendingPathComponent(".secret"), atomically: true, encoding: .utf8)
        let service = ArchiveService()
        let zip = dir.appendingPathComponent("noh.zip")
        try await service.compress([folder], to: zip, options: .init(format: .zip, excludeHidden: true))
        let out = try await service.extract(zip)   // single root "src" → unwrapped to src
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("keep.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent(".secret").path))
    }

    func testCanExtractRecognizesFormats() {
        XCTAssertTrue(ArchiveService.canExtract(URL(fileURLWithPath: "/t/a.zip")))
        XCTAssertTrue(ArchiveService.canExtract(URL(fileURLWithPath: "/t/a.7z")))
        XCTAssertTrue(ArchiveService.canExtract(URL(fileURLWithPath: "/t/a.rar")))
        XCTAssertTrue(ArchiveService.canExtract(URL(fileURLWithPath: "/t/a.tar.xz")))
        XCTAssertTrue(ArchiveService.canExtract(URL(fileURLWithPath: "/t/a.tgz")))
        XCTAssertFalse(ArchiveService.canExtract(URL(fileURLWithPath: "/t/a.txt")))
    }

    func testSevenZipRoundTripWhenAvailable() async throws {
        try XCTSkipUnless(ArchiveService.sevenZipAvailable, "7zz not resolvable in test context")
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = try seedFile(in: dir, name: "doc.txt", body: "seven")
        let service = ArchiveService()
        let arc = dir.appendingPathComponent("out.7z")
        try await service.compress([file], to: arc, options: .init(format: .sevenZip, level: 5, password: "pw1"))
        // Wrong/no password rejected, right one recovers (7z AES-256 + header enc).
        do { _ = try await service.extract(arc); XCTFail("expected needsPassword") }
        catch ArchiveService.ArchiveError.needsPassword {}
        let extracted = try await service.extract(arc, password: "pw1")
        XCTAssertEqual(try? String(contentsOf: extracted, encoding: .utf8), "seven")
    }

    func testSevenZipFormatGatedOnAvailability() {
        XCTAssertEqual(ArchiveService.availableFormats.contains(.sevenZip),
                       ArchiveService.sevenZipAvailable)
        XCTAssertTrue(ArchiveService.CompressionFormat.sevenZip.supportsPassword)
        XCTAssertTrue(ArchiveService.CompressionFormat.sevenZip.needsSevenZip)
    }

    func testFormatMetadata() {
        XCTAssertTrue(ArchiveService.CompressionFormat.zip.supportsPassword)
        XCTAssertFalse(ArchiveService.CompressionFormat.tarGz.supportsPassword)
        XCTAssertTrue(ArchiveService.CompressionFormat.tarGz.supportsLevel)
        XCTAssertFalse(ArchiveService.CompressionFormat.tarBz2.supportsLevel)
        XCTAssertEqual(ArchiveService.CompressionFormat.tarXz.fileExtension, "tar.xz")
    }
}
