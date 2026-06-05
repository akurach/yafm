import Foundation
import XCTest
@testable import Core

/// v0.9 "1.0 candidate": transformer + previewer extension points, the API
/// freeze, and the OPS-1 atomic-replace data-loss fix.
@MainActor
final class TransformerTests: XCTestCase {

    func testLowercase() {
        XCTAssertEqual(LowercaseTransformer().transform(name: "ReadMe.MD", index: 0), "readme.md")
    }

    func testSequenceZeroPads() {
        let t = SequenceTransformer(start: 1, width: 3)
        let names = ["a.txt", "b.txt", "c.txt"]
        XCTAssertEqual(applyTransformer(t, to: names),
                       ["001 - a.txt", "002 - b.txt", "003 - c.txt"])
    }

    func testSpaceReplace() {
        XCTAssertEqual(SpaceReplaceTransformer(separator: "_").transform(name: "my file.txt", index: 0),
                       "my_file.txt")
    }

    func testRegistrySeedsBuiltInsAndResolvesPreviewer() {
        let reg = ExtensionRegistry()
        XCTAssertGreaterThanOrEqual(reg.transformers.count, 3)
        XCTAssertNotNil(reg.previewer(forExtension: "LOG"))   // case-insensitive
        XCTAssertNil(reg.previewer(forExtension: "png"))      // QuickLook territory
    }

    func testCustomPreviewerRegisters() {
        struct Parquet: Previewer { let id = "p.parquet"; let title = "Parquet"; let handledExtensions = ["parquet"] }
        let reg = ExtensionRegistry()
        XCTAssertNil(reg.previewer(forExtension: "parquet"))   // not covered by built-ins
        reg.register(previewer: Parquet())
        XCTAssertEqual(reg.previewer(forExtension: "parquet")?.title, "Parquet")
    }

    func testAPIIsFrozenAtOne() {
        XCTAssertTrue(PluginAPI.frozen)
        XCTAssertEqual(PluginAPI.currentVersion, "1.0")
    }
}

/// OPS-1: a `.replace` copy must swap atomically — the original survives a
/// successful replace, and no temp file is left behind.
final class AtomicReplaceTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ops1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testReplaceOverwritesAndLeavesNoTemp() async throws {
        let srcDir = dir.appendingPathComponent("src"); let dstDir = dir.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        try "NEW".write(to: srcDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try "OLD".write(to: dstDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let engine = FileEngine()
        let task = OperationTask(kind: .copy, sources: [srcDir.appendingPathComponent("f.txt")],
                                 destination: dstDir, collision: .replace)
        for await _ in engine.run(task) {}

        let result = try String(contentsOf: dstDir.appendingPathComponent("f.txt"), encoding: .utf8)
        XCTAssertEqual(result, "NEW")
        // No .yafm-tmp-* residue.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dstDir.path)
            .filter { $0.hasPrefix(".yafm-tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "atomic replace must clean up its temp")
    }

    func testExclusiveCreateDoesNotFollowSymlinkAtDestination() async throws {
        // A symlink planted at the destination must not be followed (O_NOFOLLOW):
        // keepBoth picks a unique name, but verify a direct replace target that is
        // a symlink doesn't write through it.
        let srcDir = dir.appendingPathComponent("s"); let dstDir = dir.appendingPathComponent("d")
        let outside = dir.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        try "SECRET".write(to: outside, atomically: true, encoding: .utf8)
        try "PAYLOAD".write(to: srcDir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        // dst/f.txt -> ../outside.txt  (replace must swap the link, not the target)
        try FileManager.default.createSymbolicLink(at: dstDir.appendingPathComponent("f.txt"),
                                                   withDestinationURL: outside)

        let engine = FileEngine()
        let task = OperationTask(kind: .copy, sources: [srcDir.appendingPathComponent("f.txt")],
                                 destination: dstDir, collision: .replace)
        for await _ in engine.run(task) {}

        // The outside secret must be untouched.
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "SECRET")
    }
}
