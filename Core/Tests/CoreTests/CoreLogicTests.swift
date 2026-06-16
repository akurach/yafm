import Foundation
import XCTest
@testable import Core

final class CoreLogicTests: XCTestCase {

    private func tmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yafm-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: FileEngine

    func testCopyStreamsBytesAndCompletes() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.bin")
        let dst = dir.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 3_000_000).write(to: src)   // 3 MB → multiple buffers

        let engine = FileEngine()
        let task = OperationTask(kind: .copy, sources: [src], destination: dst)
        var last: OperationProgress?
        for await p in engine.run(task) { last = p }

        XCTAssertEqual(last?.state, .done)
        let copied = dst.appendingPathComponent("src.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertEqual(try Data(contentsOf: copied).count, 3_000_000)
    }

    func testDeleteRemovesFile() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("x.txt")
        try "hi".write(to: f, atomically: true, encoding: .utf8)
        let engine = FileEngine()
        for await _ in engine.run(OperationTask(kind: .delete, sources: [f])) {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
    }

    func testCopyDoesNotFollowSymlinkOutOfTree() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // A secret outside the copied tree.
        let secret = dir.appendingPathComponent("secret.txt")
        try "TOPSECRET".write(to: secret, atomically: true, encoding: .utf8)
        // A source folder containing a symlink that points at the secret.
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: src.appendingPathComponent("link"), withDestinationURL: secret)
        let dst = dir.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let engine = FileEngine()
        for await _ in engine.run(OperationTask(kind: .copy, sources: [src], destination: dst)) {}

        // The copied link must remain a symlink, NOT a materialized copy of the secret.
        let copied = dst.appendingPathComponent("src/link")
        let rv = try copied.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(rv.isSymbolicLink, true, "symlink was followed — path-traversal copy-out")
    }

    func testUniqueDestinationAvoidsCollision() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("a.txt")
        try "1".write(to: original, atomically: true, encoding: .utf8)
        let unique = FileEngine.uniqueDestination(for: original, in: dir)
        XCTAssertEqual(unique.lastPathComponent, "a copy.txt")
    }

    // MARK: Sorting

    func testSortDirectoriesFirstThenName() {
        let e = { (name: String, dir: Bool) in
            FSEntry(url: URL(fileURLWithPath: "/\(name)"), name: name, isDirectory: dir, isHidden: false, size: 0, modified: nil)
        }
        let input = [e("zeta", false), e("Beta", true), e("alpha", false), e("Alpha", true)]
        let sorted = input.sorted(by: SortOrder(key: .name, ascending: true))
        XCTAssertEqual(sorted.map(\.name), ["Alpha", "Beta", "alpha", "zeta"])
    }

    // MARK: Bulk rename

    func testRenameRuleRegexAndSequence() {
        let rule = RenameRule(pattern: "IMG", replacement: "Photo_#", useRegex: true, sequenceStart: 1)
        let out = rule.preview(["IMG.jpg", "IMG.png"])
        XCTAssertEqual(out.map(\.to), ["Photo_01.jpg", "Photo_02.png"])
    }

    // MARK: Color coding

    func testColorCoderMatchesExtension() {
        // Extension-based defaults were removed (file *type* color now lives in the
        // tile + opt-in name tint, to avoid two conflicting palettes). The default
        // coder no longer colors by extension; an explicit rule still matches.
        let png = FSEntry(url: URL(fileURLWithPath: "/a.png"), name: "a.png", isDirectory: false, isHidden: false, size: 0, modified: nil)
        XCTAssertNil(ColorCoder().colorName(for: png))
        let coder = ColorCoder(rules: [ColorRule(match: .ext(["png"]), colorName: "Purple")])
        XCTAssertEqual(coder.colorName(for: png), "Purple")
    }

    // MARK: Tags xattr roundtrip

    func testTagWriteReadRoundtrip() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("tagged.txt")
        try "x".write(to: f, atomically: true, encoding: .utf8)

        let service = TagService()
        try await service.setTags([Tag(name: "Work", colorIndex: 6), Tag(name: "Urgent")], on: f)
        let read = await service.tags(of: f)
        XCTAssertEqual(Set(read.map(\.name)), ["Work", "Urgent"])
        XCTAssertEqual(read.first { $0.name == "Work" }?.colorIndex, 6)

        let known = await service.allKnownTags()
        XCTAssertTrue(known.contains { $0.name == "Work" })
        let entries = await service.entries(taggedWith: Tag(name: "Work"))
        XCTAssertEqual(entries, [f])
    }

    /// Background index (§5) populates the cloud from a cold service that has
    /// never read the file individually.
    func testIndexPopulatesTagCloudFromRoot() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("report.txt")
        try "x".write(to: f, atomically: true, encoding: .utf8)
        try await TagService().setTags([Tag(name: "Finance")], on: f)

        // A fresh service: empty index until it walks the tree.
        let cold = TagService()
        let before = await cold.allKnownTags()
        XCTAssertTrue(before.isEmpty)
        await cold.index(roots: [dir])
        let after = await cold.allKnownTags()
        XCTAssertTrue(after.contains { $0.name == "Finance" })
        let entries = await cold.entries(taggedWith: Tag(name: "Finance"))
        // Enumerator yields the symlink-resolved path (/private/var vs /var).
        XCTAssertEqual(entries.map(\.lastPathComponent), ["report.txt"])
    }
}
