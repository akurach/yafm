import Foundation
import XCTest
@testable import Core

/// Never-freeze stress harness. yafm's defining promise is that filesystem work
/// never blocks silently — historically defended by whack-a-mole (a corrupt column
/// width, an O(n²) sort, a sync eject, a sync trash have each frozen the UI). These
/// tests turn the promise into something CI can *prove*: each adversarial scenario
/// must finish within a wall-clock ceiling, so a regression that reintroduces a hang
/// or a quadratic blowup fails as a timeout instead of shipping.
///
/// Scope: the Core engine + listing run off the main actor by design, so this guards
/// exactly that freeze surface (the class of bug that keeps recurring). App-layer
/// main-thread blocks (e.g. a sync call in a SwiftUI view) are not observable here.
///
/// Opt-in — these build a large tree on disk and are too slow for the default suite.
/// Run with `YAFM_STRESS=1 swift test --filter StressTests` (CI wires this as a
/// separate step). Ceilings are deliberately generous: they catch a true hang, not
/// a slow-but-linear machine.
final class StressTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YAFM_STRESS"] == "1",
                          "stress tests are opt-in (set YAFM_STRESS=1)")
    }

    private func tmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yafm-stress-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Listing a very large folder streams to completion promptly — no unbounded
    /// pre-sort or per-entry stat storm that would stall the "reading…" state.
    func testListLargeFolderStreamsWithoutStalling() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let n = 20_000
        for i in 0..<n {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("f\(i).txt").path, contents: nil)
        }

        let fs = LocalFileSystem()
        let start = Date()
        var got = 0
        for await event in fs.list(dir) {
            if case .entries(let batch) = event { got += batch.count }   // entries stream in chunks
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(got, n, "listing dropped entries")
        XCTAssertLessThan(elapsed, 20, "listing \(n) entries stalled (\(elapsed)s) — possible main-thread/O(n²) regression")
    }

    /// Copying a wide tree completes and reproduces every file within bound.
    func testCopyWideTreeCompletes() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let n = 3_000
        for i in 0..<n {
            try Data(repeating: UInt8(i & 0xff), count: 256).write(to: src.appendingPathComponent("f\(i).bin"))
        }
        let dst = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let engine = FileEngine()
        let start = Date()
        var last: OperationProgress?
        for await p in engine.run(OperationTask(kind: .copy, sources: [src], destination: dst)) { last = p }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(last?.state, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("tree/f\(n-1).bin").path))
        XCTAssertLessThan(elapsed, 30, "copying \(n) files stalled (\(elapsed)s)")
    }

    /// Cancelling a large copy interrupts promptly and leaves no truncated file —
    /// the copy neither runs to completion nor hangs waiting to be killed.
    func testCancelLargeCopyIsPromptAndClean() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("huge.bin")
        try Data(repeating: 7, count: 256 << 20).write(to: src)   // 256 MiB
        let dst = dir.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let engine = FileEngine()
        let task = OperationTask(kind: .copy, sources: [src], destination: dst)
        var cancelledOnce = false
        let start = Date()
        var last: OperationProgress?
        for await p in engine.run(task) {
            last = p
            if !cancelledOnce, p.state == .running, p.completedBytes > 0, p.completedBytes < p.totalBytes {
                engine.cancel(task.id); cancelledOnce = true
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(last?.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent("huge.bin").path),
                       "cancelled copy left a truncated file")
        XCTAssertLessThan(elapsed, 15, "cancel was not observed promptly (\(elapsed)s)")
    }

    /// A write-denied destination fails cleanly and fast — never a spin or a hang.
    func testWriteDeniedTreeFailsFast() async throws {
        try XCTSkipIf(getuid() == 0, "root ignores POSIX permissions")
        let dir = try tmpDir()
        let src = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for i in 0..<200 { try "x".write(to: src.appendingPathComponent("f\(i)"), atomically: true, encoding: .utf8) }
        let dst = dir.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dst.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dst.path)
            try? FileManager.default.removeItem(at: dir)
        }

        let engine = FileEngine()
        let start = Date()
        var last: OperationProgress?
        for await p in engine.run(OperationTask(kind: .copy, sources: [src], destination: dst)) { last = p }
        let elapsed = Date().timeIntervalSince(start)
        guard case .failed = last?.state else {
            return XCTFail("expected .failed, got \(String(describing: last?.state))")
        }
        XCTAssertLessThan(elapsed, 10, "failure path stalled (\(elapsed)s)")
    }
}
