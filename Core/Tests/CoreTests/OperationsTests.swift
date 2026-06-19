import Foundation
import XCTest
@testable import Core

/// Coverage for the gaps the 2026-06-05 audit flagged (T-1…T-12): cancellation,
/// move/rename, recursive copy, n≥3 collisions, delete progress, regex edges,
/// missing-source errors, listing cancellation, and tag invalidation/persistence.
final class OperationsTests: XCTestCase {

    private func tmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yafm-ops-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: T-1 — cancel mid-copy actually stops (the B-2 regression)

    func testCancelMidCopyStops() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("big.bin")
        let dst = dir.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        // 64 MiB → ~64 one-MiB buffer iterations, plenty of cancel checkpoints.
        try Data(repeating: 9, count: 64 << 20).write(to: src)

        let engine = FileEngine()
        let task = OperationTask(kind: .copy, sources: [src], destination: dst)
        var last: OperationProgress?
        var cancelledOnce = false
        for await p in engine.run(task) {
            last = p
            // Cancel as soon as we've seen real bytes move but before completion.
            if !cancelledOnce, p.state == .running, p.completedBytes > 0, p.completedBytes < p.totalBytes {
                engine.cancel(task.id)
                cancelledOnce = true
            }
        }
        XCTAssertEqual(last?.state, .cancelled, "cancel did not interrupt the copy")
        XCTAssertLessThan(last?.completedBytes ?? .max, 64 << 20, "copy ran to completion despite cancel")
    }

    // MARK: T-2 — move relocates the file

    func testMoveRelocatesFile() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("m.txt")
        let destDir = dir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try "move me".write(to: src, atomically: true, encoding: .utf8)

        let engine = FileEngine()
        for await _ in engine.run(OperationTask(kind: .move, sources: [src], destination: destDir)) {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("m.txt").path))
    }

    // MARK: Move onto an existing file with .replace (was: moveItem threw)

    func testMoveReplaceOntoExistingFileSucceeds() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("m.txt")
        let destDir = dir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try "new".write(to: src, atomically: true, encoding: .utf8)
        let dst = destDir.appendingPathComponent("m.txt")
        try "old".write(to: dst, atomically: true, encoding: .utf8)   // collision

        let engine = FileEngine()
        for await _ in engine.run(OperationTask(kind: .move, sources: [src],
                                                destination: destDir, collision: .replace)) {}

        // Source gone, destination overwritten with the new content — the
        // copy-then-delete fallback (moveItem can't overwrite) did its job.
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "new")
    }

    // MARK: Cross-volume (EXDEV) detection drives the copy+delete fallback

    func testIsCrossDeviceDetectsEXDEV() {
        let direct = NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
        XCTAssertTrue(FileEngine.isCrossDevice(direct))

        // FileManager wraps the POSIX failure under NSUnderlyingErrorKey.
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 512,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))])
        XCTAssertTrue(FileEngine.isCrossDevice(wrapped))

        // A permission error (EACCES) must NOT be treated as cross-device.
        XCTAssertFalse(FileEngine.isCrossDevice(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    // MARK: T-3 — rename changes only the leaf name

    func testRenameChangesLeafName() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("old.txt")
        try "x".write(to: src, atomically: true, encoding: .utf8)

        let engine = FileEngine()
        for await _ in engine.run(OperationTask(kind: .rename(to: "new.txt"), sources: [src])) {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.txt").path))
    }

    // MARK: T-4 — recursive copy reproduces the whole tree

    func testRecursiveCopyCopiesNestedTree() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("tree")
        let nested = src.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "1".write(to: src.appendingPathComponent("top.txt"), atomically: true, encoding: .utf8)
        try "2".write(to: nested.appendingPathComponent("deep.txt"), atomically: true, encoding: .utf8)
        let dst = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let engine = FileEngine()
        var last: OperationProgress?
        for await p in engine.run(OperationTask(kind: .copy, sources: [src], destination: dst)) { last = p }

        XCTAssertEqual(last?.state, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("tree/top.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("tree/a/b/deep.txt").path))
    }

    // MARK: T-5 — third-and-beyond collision naming

    func testUniqueDestinationThirdCollision() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.txt", "a copy.txt"] {
            try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let unique = FileEngine.uniqueDestination(for: dir.appendingPathComponent("a.txt"), in: dir)
        XCTAssertEqual(unique.lastPathComponent, "a copy 3.txt")
    }

    // MARK: T-5b — collision policy: skip leaves the existing file untouched

    func testCollisionSkipKeepsExistingAndSkipsSource() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.txt")
        let dst = dir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try "new".write(to: src, atomically: true, encoding: .utf8)
        try "old".write(to: dst.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let engine = FileEngine()
        var last: OperationProgress?
        for await p in engine.run(OperationTask(kind: .copy, sources: [src], destination: dst, collision: .skip)) { last = p }

        XCTAssertEqual(last?.state, .done)
        // No "a copy.txt" created, and the existing file is unchanged.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a copy.txt").path))
        let kept = try String(contentsOf: dst.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(kept, "old")
    }

    // MARK: T-5c — collision policy: replace overwrites the existing file

    func testCollisionReplaceOverwritesExisting() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.txt")
        let dst = dir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try "new".write(to: src, atomically: true, encoding: .utf8)
        try "old".write(to: dst.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let engine = FileEngine()
        var last: OperationProgress?
        for await p in engine.run(OperationTask(kind: .copy, sources: [src], destination: dst, collision: .replace)) { last = p }

        XCTAssertEqual(last?.state, .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a copy.txt").path))
        let replaced = try String(contentsOf: dst.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(replaced, "new")
    }

    // MARK: T-5d — collision policy: keepBoth (default) renames the copy

    func testCollisionKeepBothRenamesCopy() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.txt")
        let dst = dir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try "new".write(to: src, atomically: true, encoding: .utf8)
        try "old".write(to: dst.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let engine = FileEngine()
        for await _ in engine.run(OperationTask(kind: .copy, sources: [src], destination: dst, collision: .keepBoth)) {}

        // Both survive: original untouched, source landed as "a copy.txt".
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("a.txt"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("a copy.txt"), encoding: .utf8), "new")
    }

    // MARK: T-5e — clear() drops the in-memory index without touching xattrs

    func testClearDropsIndex() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("c.txt")
        try "x".write(to: f, atomically: true, encoding: .utf8)
        let service = TagService(storeURL: nil)
        try await service.setTags([Tag(name: "Live")], on: f)
        let known = await service.allKnownTags()
        XCTAssertFalse(known.isEmpty)

        await service.clear()
        let afterClear = await service.allKnownTags()
        XCTAssertTrue(afterClear.isEmpty)
        // xattr untouched — a fresh read still sees the tag on disk.
        let onDisk = await service.tags(of: f)
        XCTAssertTrue(onDisk.contains { $0.name == "Live" })
    }

    // MARK: T-6 — delete reports real, non-zero byte progress (M-9/M-10)

    func testDeleteFolderReportsRecursiveBytes() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("f1"))
        try Data(repeating: 2, count: 8192).write(to: folder.appendingPathComponent("f2"))

        let engine = FileEngine()
        var last: OperationProgress?
        for await p in engine.run(OperationTask(kind: .delete, sources: [folder])) { last = p }

        XCTAssertEqual(last?.state, .done)
        XCTAssertEqual(last?.totalBytes, 4096 + 8192, "delete total should recurse into the folder")
        XCTAssertEqual(last?.completedBytes, last?.totalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: T-7 — copying a missing source surfaces a failure, never a silent done

    func testMissingSourceFails() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let dst = dir.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let ghost = dir.appendingPathComponent("does-not-exist.bin")

        let engine = FileEngine()
        var last: OperationProgress?
        for await p in engine.run(OperationTask(kind: .copy, sources: [ghost], destination: dst)) { last = p }

        guard case .failed = last?.state else {
            return XCTFail("expected .failed for a missing source, got \(String(describing: last?.state))")
        }
    }

    // MARK: T-8 — listing cancellation terminates instead of hanging

    func testListingCancellationTerminates() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<400 {
            try "x".write(to: dir.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
        }
        let fs = LocalFileSystem()
        var got = 0
        for await event in fs.list(dir) {
            if case .entries(let batch) = event { got += batch.count; break } // break → stream termination → task.cancel()
        }
        XCTAssertGreaterThan(got, 0)   // reaching here without hanging is the assertion
    }

    // MARK: T-9 — ColorRule regex edges

    func testColorRuleNameRegexMatches() {
        let rule = ColorRule(match: .nameRegex("^IMG_"), colorName: "Red")
        let hit = FSEntry(url: URL(fileURLWithPath: "/IMG_001.jpg"), name: "IMG_001.jpg", isDirectory: false, isHidden: false, size: 0, modified: nil)
        let miss = FSEntry(url: URL(fileURLWithPath: "/photo.jpg"), name: "photo.jpg", isDirectory: false, isHidden: false, size: 0, modified: nil)
        XCTAssertTrue(rule.matches(hit))
        XCTAssertFalse(rule.matches(miss))
    }

    func testColorRuleInvalidRegexNeverMatches() {
        let rule = ColorRule(match: .nameRegex("(unterminated"), colorName: "Red")
        let any = FSEntry(url: URL(fileURLWithPath: "/x"), name: "x", isDirectory: false, isHidden: false, size: 0, modified: nil)
        XCTAssertFalse(rule.matches(any))   // invalid pattern → no crash, no match
    }

    // MARK: T-10 — non-regex (literal) rename

    func testRenameRuleLiteralReplacement() {
        let rule = RenameRule(pattern: "draft", replacement: "final", useRegex: false)
        let out = rule.preview(["draft-1.txt", "report.txt"])
        XCTAssertEqual(out.map(\.to), ["final-1.txt", "report.txt"])
    }

    // MARK: T-11 — tag invalidation: forget drops a URL from the index

    func testForgetRemovesURLFromIndex() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("t.txt")
        try "x".write(to: f, atomically: true, encoding: .utf8)
        let service = TagService(storeURL: nil)
        try await service.setTags([Tag(name: "Keep")], on: f)
        let before = await service.entries(taggedWith: Tag(name: "Keep"))
        XCTAssertEqual(before, [f])

        await service.forget(f)
        let after = await service.entries(taggedWith: Tag(name: "Keep"))
        XCTAssertTrue(after.isEmpty)
    }

    // MARK: T-12 — index persistence survives a cold service

    func testTagIndexPersistRoundTrip() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("index.json")
        let f = dir.appendingPathComponent("p.txt")
        try "x".write(to: f, atomically: true, encoding: .utf8)

        let hot = TagService(storeURL: store)
        try await hot.setTags([Tag(name: "Archive", colorIndex: 4)], on: f)
        await hot.persist()

        let cold = TagService(storeURL: store)
        await cold.loadPersisted()
        let known = await cold.allKnownTags()
        XCTAssertTrue(known.contains { $0.name == "Archive" && $0.colorIndex == 4 })
        let entries = await cold.entries(taggedWith: Tag(name: "Archive"))
        XCTAssertEqual(entries, [f])
    }
}
