import Foundation
import XCTest
@testable import Core

/// Covers the v0.6 content search (grep-in-files) streaming API: it finds the
/// substring inside file contents, streams hits, skips binary/oversized files,
/// and honours cancellation + bounds.
final class SearchTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yafm-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ contents: Data) throws {
        try contents.write(to: dir.appendingPathComponent(name))
    }
    private func write(_ name: String, _ text: String) throws {
        try write(name, Data(text.utf8))
    }

    private func collect(_ query: String, mode: SearchMode) async -> [String] {
        var names: [String] = []
        for await url in SearchService().searchStream(query, in: dir, mode: mode) {
            names.append(url.lastPathComponent)
        }
        return names.sorted()
    }

    func testContentSearchFindsSubstringInFiles() async throws {
        try write("a.txt", "the quick brown fox")
        try write("b.txt", "lazy dog sleeps")
        try write("c.txt", "FOX hunting at dawn")   // case-insensitive
        let hits = await collect("fox", mode: .content)
        XCTAssertEqual(hits, ["a.txt", "c.txt"])
    }

    func testContentSearchSkipsBinaryFiles() async throws {
        // A NUL byte in the first chunk marks it binary → skipped even if the
        // needle's bytes appear later.
        var bin = Data([0x00, 0x01, 0x02])
        bin.append(Data("needle".utf8))
        try write("blob.bin", bin)
        try write("plain.txt", "needle here")
        let hits = await collect("needle", mode: .content)
        XCTAssertEqual(hits, ["plain.txt"])
    }

    func testContentSearchSkipsOversizedFiles() async throws {
        let big = String(repeating: "x", count: SearchService.contentFileSizeCap + 1024) + "needle"
        try write("huge.txt", big)
        try write("small.txt", "needle")
        let hits = await collect("needle", mode: .content)
        XCTAssertEqual(hits, ["small.txt"])
    }

    func testNameStreamFindsBySubstring() async throws {
        try write("report-2026.txt", "")
        try write("notes.md", "")
        // Spotlight won't have indexed a fresh temp dir, so this exercises the
        // walk fallback path of the streaming name search.
        let hits = await collect("report", mode: .name)
        XCTAssertTrue(hits.contains("report-2026.txt"))
        XCTAssertFalse(hits.contains("notes.md"))
    }

    func testEmptyQueryYieldsNothing() async throws {
        try write("a.txt", "anything")
        let hits = await collect("   ", mode: .content)
        XCTAssertTrue(hits.isEmpty)
    }
}
