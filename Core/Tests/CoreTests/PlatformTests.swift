import Foundation
import XCTest
@testable import Core

/// v0.3 Platform: JS plugin runtime, search, git-status column.
final class PlatformTests: XCTestCase {

    private func tmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yafm-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(_ name: String, dir: Bool = false) -> FSEntry {
        FSEntry(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
                isDirectory: dir, isHidden: false, size: 10, modified: nil)
    }

    // MARK: JS plugin runtime

    @MainActor
    func testPluginRegistersAndEvaluatesColumn() {
        let host = JSPluginHost()
        let src = """
        yafm.registerColumn({ id: "up", title: "Upper",
          value: function (e) { return e.name.toUpperCase(); } });
        """
        let cols = host.load(source: src, name: "upper.js")
        XCTAssertTrue(host.errors.isEmpty, "\(host.errors)")
        XCTAssertEqual(cols.count, 1)
        XCTAssertEqual(cols[0].title, "Upper")
        XCTAssertTrue(cols[0].id.hasPrefix(JSPluginHost.columnIDPrefix))
        XCTAssertEqual(cols[0].evaluate(entry("Hello.txt")), .text("HELLO.TXT"))
    }

    @MainActor
    func testPluginSnapshotExposesExtAndDirectoryButNotPath() {
        let host = JSPluginHost()
        // A plugin can read ext + isDirectory, but `entry.url`/path is absent.
        let src = """
        yafm.registerColumn({ id: "k", title: "K", value: function (e) {
          if (e.url || e.path) return "LEAK";
          return e.isDirectory ? "dir" : e.ext;
        }});
        """
        let cols = host.load(source: src, name: "snap.js")
        XCTAssertEqual(cols.count, 1)
        XCTAssertEqual(cols[0].evaluate(entry("a.swift")), .text("swift"))
        XCTAssertEqual(cols[0].evaluate(entry("Folder", dir: true)), .text("dir"))
    }

    @MainActor
    func testPluginNumberValueAndThrowingIsContained() {
        let host = JSPluginHost()
        let cols = host.load(source: """
        yafm.registerColumn({ id: "n", title: "N", value: function (e) { return e.name.length; }});
        yafm.registerColumn({ id: "boom", title: "Boom", value: function () { throw new Error("x"); }});
        """, name: "mix.js")
        XCTAssertEqual(cols.count, 2)
        XCTAssertEqual(cols[0].evaluate(entry("abc")), .number(3))
        // A throwing column degrades to an empty cell, never a crash.
        XCTAssertEqual(cols[1].evaluate(entry("abc")), .none)
    }

    @MainActor
    func testMalformedPluginRecordsErrorAndRegistersNothing() {
        let host = JSPluginHost()
        let cols = host.load(source: "this is not valid javascript ===", name: "bad.js")
        XCTAssertTrue(cols.isEmpty)
        XCTAssertFalse(host.errors.isEmpty)
        XCTAssertEqual(host.errors.first?.name, "bad.js")
    }

    @MainActor
    func testBundledExamplePluginClassifiesByExtension() {
        // The example we seed on first run must actually load and classify.
        let host = JSPluginHost()
        let cols = host.load(source: JSPluginHost.exampleColumnPlugin, name: "example-kind.js")
        XCTAssertTrue(host.errors.isEmpty, "\(host.errors)")
        XCTAssertEqual(cols.count, 1)
        XCTAssertEqual(cols[0].title, "Type")
        XCTAssertEqual(cols[0].evaluate(entry("photo.jpg")), .text("🖼 Image"))
        XCTAssertEqual(cols[0].evaluate(entry("main.swift")), .text("⚙︎ Code"))
        XCTAssertEqual(cols[0].evaluate(entry("src", dir: true)), .text("📁 Folder"))
    }

    // MARK: Search

    func testSearchFallbackFindsByNameSubstring() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("report.md"))
        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data().write(to: sub.appendingPathComponent("report2.md"))

        let hits = await SearchService().search("report", in: dir)
        let names = Set(hits.map(\.lastPathComponent))
        XCTAssertTrue(names.contains("report.md"))
        XCTAssertTrue(names.contains("report2.md"))
        XCTAssertFalse(names.contains("notes.txt"))
    }

    func testSearchEmptyQueryReturnsNothing() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.txt"))
        let hits = await SearchService().search("   ", in: dir)
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: Git status

    func testGitStatusMarksUntrackedAndRollsUpSubfolders() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        guard runGit(["init"], in: dir) else { throw XCTSkip("git not available") }

        // Commit a file inside sub/ so the folder is *tracked* — only then does
        // git report the inner change (and we roll it up) rather than collapsing
        // an entirely-untracked dir to a single "?? sub/" line.
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let inner = sub.appendingPathComponent("inner.txt")
        try "v1".write(to: inner, atomically: true, encoding: .utf8)
        XCTAssertTrue(runGit(["add", "."], in: dir))
        XCTAssertTrue(runGit(["-c", "user.email=t@example.com", "-c", "user.name=t",
                              "commit", "-m", "init"], in: dir))

        // Now: modify the tracked inner file + add a brand-new untracked file.
        try "v2-changed".write(to: inner, atomically: true, encoding: .utf8)
        try Data().write(to: dir.appendingPathComponent("new.txt"))

        let map = await GitStatusService().status(forDirectory: dir)
        XCTAssertEqual(map["new.txt"], "?")          // untracked direct child
        XCTAssertEqual(map["sub"], "•")              // inner change rolled up onto the folder
    }

    func testGitStatusEmptyOutsideRepo() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.txt"))
        let map = await GitStatusService().status(forDirectory: dir)
        XCTAssertTrue(map.isEmpty)
    }

    // MARK: Tag manager (rename / delete / recolor across files)

    func testTagRecolorRenameDeleteAcrossFiles() async throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.txt")
        try "x".write(to: f, atomically: true, encoding: .utf8)

        let svc = TagService(storeURL: nil)
        try await svc.setTags([Tag(name: "work", colorIndex: 5)], on: f)

        // Recolor across all files carrying it.
        let recolored = await svc.recolorTag("work", colorIndex: 6)
        XCTAssertEqual(recolored, 1)
        let afterRecolor = await svc.tags(of: f).first?.colorIndex
        XCTAssertEqual(afterRecolor, 6)

        // Rename across all files (xattr rewritten).
        let renamed = await svc.renameTag("work", to: "job")
        XCTAssertEqual(renamed, 1)
        let afterRename = await svc.tags(of: f).map(\.name)
        XCTAssertEqual(afterRename, ["job"])
        let known = await svc.allKnownTags().map(\.name)
        XCTAssertFalse(known.contains("work"))

        // Delete from all files; the file itself survives.
        let deleted = await svc.deleteTag("job")
        XCTAssertEqual(deleted, 1)
        let afterDelete = await svc.tags(of: f)
        XCTAssertTrue(afterDelete.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
