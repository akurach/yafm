import Foundation
import XCTest
@testable import Core

/// v0.8 "Make it yours": manifest parsing/validation, the scoped read:cwd
/// capability (host-resolved, refuses escape, gated by the manifest), archive
/// tree synthesis, and the command/menu contribution surface.
final class PluginManifestTests: XCTestCase {

    private func manifestData(_ json: String) -> Data { Data(json.utf8) }

    func testParsesValidManifest() throws {
        let m = try PluginManifest.parse(manifestData("""
        {"manifest":1,"id":"com.x.y","name":"Y","version":"1.2.0","apiVersion":"1.0",
         "capabilities":["read:cwd","contribute:command"],
         "contributes":{"columns":["C"],"commands":["Do"]},"author":"me"}
        """))
        XCTAssertEqual(m.id, "com.x.y")
        XCTAssertTrue(m.grants(.readCwd))
        XCTAssertTrue(m.grants(.computeColumn))   // always implicitly granted
        XCTAssertEqual(m.trust, .declaredAuthor)
        XCTAssertEqual(m.contributes.commands, ["Do"])
    }

    func testRejectsUnsupportedManifestVersion() {
        XCTAssertThrowsError(try PluginManifest.parse(manifestData(
            #"{"manifest":2,"id":"a","name":"a","version":"1","apiVersion":"1.0"}"#))) {
            XCTAssertEqual($0 as? PluginManifestError, .unsupportedManifestVersion(2))
        }
    }

    func testRejectsIncompatibleAPI() {
        XCTAssertThrowsError(try PluginManifest.parse(manifestData(
            #"{"manifest":1,"id":"a","name":"a","version":"1","apiVersion":"2.0"}"#))) {
            XCTAssertEqual($0 as? PluginManifestError, .incompatibleAPI(plugin: "2.0", host: "1.0"))
        }
    }

    func testRejectsMissingID() {
        XCTAssertThrowsError(try PluginManifest.parse(manifestData(
            #"{"manifest":1,"id":"","name":"a","version":"1","apiVersion":"1.0"}"#))) {
            XCTAssertEqual($0 as? PluginManifestError, .missingID)
        }
    }

    func testAPICompatibilityIsMajorOnly() {
        XCTAssertTrue(PluginAPI.isCompatible(pluginAPI: "1.9"))
        XCTAssertFalse(PluginAPI.isCompatible(pluginAPI: "0.9"))
    }

    func testComputeColumnNeedsNoConsentButReadCwdDoes() {
        XCTAssertFalse(PluginCapability.computeColumn.requiresConsent)
        XCTAssertTrue(PluginCapability.readCwd.requiresConsent)
    }
}

@MainActor
final class PluginCapabilityTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("plug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func column(_ source: String, manifest: PluginManifest?, host: JSPluginHost,
                        entry: FSEntry) -> ColumnValue {
        let cols = host.load(source: source, name: "p.js", manifest: manifest)
        guard let col = cols.first else { return .none }
        return col.evaluate(entry)
    }

    func testReadCwdReadsScopedFileWhenGranted() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: folder.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        let manifest = PluginManifest(id: "t.read", name: "r", version: "1", apiVersion: "1.0",
                                      capabilities: [.readCwd])
        let src = """
        yafm.registerColumn({ id:"h", title:"H", value:function(e){
          var t = yafm.readText(e, "HEAD"); return t ? t.trim() : "NONE";
        }});
        """
        let entry = FSEntry(url: folder, name: "repo", isDirectory: true, isHidden: false, size: nil, modified: nil)
        XCTAssertEqual(column(src, manifest: manifest, host: JSPluginHost(), entry: entry),
                       .text("ref: refs/heads/main"))
    }

    func testReadTextRefusesEscapeOutsideScope() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("inner")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A secret one level up — must NOT be reachable via "../".
        try "TOPSECRET".write(to: dir.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

        let manifest = PluginManifest(id: "t.escape", name: "e", version: "1", apiVersion: "1.0",
                                      capabilities: [.readCwd])
        let src = """
        yafm.registerColumn({ id:"x", title:"X", value:function(e){
          var t = yafm.readText(e, "../secret.txt"); return t ? "LEAKED" : "denied";
        }});
        """
        let entry = FSEntry(url: folder, name: "inner", isDirectory: true, isHidden: false, size: nil, modified: nil)
        XCTAssertEqual(column(src, manifest: manifest, host: JSPluginHost(), entry: entry), .text("denied"))
    }

    func testReadTextAbsentWithoutCapability() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "data".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        // No manifest → compute-only → yafm.readText is undefined.
        let src = """
        yafm.registerColumn({ id:"x", title:"X", value:function(e){
          return (typeof yafm.readText === "function") ? "HAS" : "none";
        }});
        """
        let entry = FSEntry(url: dir.appendingPathComponent("f.txt"), name: "f.txt",
                            isDirectory: false, isHidden: false, size: nil, modified: nil)
        XCTAssertEqual(column(src, manifest: nil, host: JSPluginHost(), entry: entry), .text("none"))
    }

    func testCommandsRequireCapabilityGrant() {
        let host = JSPluginHost()
        let src = """
        yafm.registerCommand({ id:"c", title:"Cmd", run:function(){} });
        yafm.registerColumn({ id:"x", title:"X", value:function(){return "ok";} });
        """
        // Manifest WITHOUT contribute:command → the command is dropped.
        let noGrant = PluginManifest(id: "n", name: "n", version: "1", apiVersion: "1.0", capabilities: [])
        _ = host.load(source: src, name: "n.js", manifest: noGrant)
        XCTAssertTrue(host.commands.isEmpty, "command must not register without the grant")

        let host2 = JSPluginHost()
        let grant = PluginManifest(id: "g", name: "g", version: "1", apiVersion: "1.0", capabilities: [.command])
        _ = host2.load(source: src, name: "g.js", manifest: grant)
        XCTAssertEqual(host2.commands.count, 1)
        XCTAssertEqual(host2.commands.first?.title, "Cmd")
    }
}

final class ArchiveTests: XCTestCase {
    private let zip = URL(fileURLWithPath: "/tmp/a.zip")

    func testSynthesizesTreeAtRoot() {
        let names = ["readme.md", "src/main.swift", "src/util/log.swift", "docs/"]
        let rows = ArchiveFileSystem.entries(in: names, inner: "", zip: zip)
        let names2 = rows.map(\.name).sorted()
        XCTAssertEqual(names2, ["docs", "readme.md", "src"])
        // src and docs are directories, readme is a file.
        XCTAssertTrue(rows.first { $0.name == "src" }!.isDirectory)
        XCTAssertFalse(rows.first { $0.name == "readme.md" }!.isDirectory)
    }

    func testSynthesizesTreeInSubdir() {
        let names = ["src/main.swift", "src/util/log.swift", "src/util/io.swift", "other/x"]
        let rows = ArchiveFileSystem.entries(in: names, inner: "src", zip: zip)
        XCTAssertEqual(rows.map(\.name).sorted(), ["main.swift", "util"])
        XCTAssertTrue(rows.first { $0.name == "util" }!.isDirectory)
    }

    func testEntryURLsRoundTripThroughArchiveLocation() {
        let rows = ArchiveFileSystem.entries(in: ["dir/file.txt"], inner: "", zip: zip)
        let dirRow = rows.first { $0.name == "dir" }!
        let loc = ArchiveLocation(url: dirRow.url)
        XCTAssertEqual(loc?.zipURL.path, zip.path)
        XCTAssertEqual(loc?.inner, "dir")
    }

    func testListingStreamsThroughStubLister() async throws {
        // The provider validates the zip is a real local .zip file; create one
        // (contents come from the stub lister, not the bytes).
        let realZip = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stub-\(UUID().uuidString).zip")
        try Data("PK".utf8).write(to: realZip)
        defer { try? FileManager.default.removeItem(at: realZip) }
        let fs = ArchiveFileSystem(lister: { _ in ["a.txt", "b/c.txt"] })
        let root = ArchiveLocation.url(zip: realZip, inner: "")!
        var names: [String] = []
        for await event in fs.list(root) {
            if case .entries(let batch) = event { names.append(contentsOf: batch.map(\.name)) }
        }
        XCTAssertEqual(names.sorted(), ["a.txt", "b"])
    }
}
