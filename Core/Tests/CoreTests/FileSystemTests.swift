import Foundation
import XCTest
@testable import Core

final class LocalFileSystemTests: XCTestCase {

    /// Lists a temp directory and confirms streamed entries cover what we created.
    func testListsDirectoryContents() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "a".write(to: tmp.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: tmp.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("sub"), withIntermediateDirectories: false)

        let fs = LocalFileSystem()
        var names: Set<String> = []
        var began = false
        var finished = false

        for await event in fs.list(tmp) {
            switch event {
            case .began: began = true
            case .entries(let batch): names.formUnion(batch.map(\.name))
            case .finished: finished = true
            case .failed(let message): XCTFail("unexpected failure: \(message)")
            }
        }

        XCTAssertTrue(began)
        XCTAssertTrue(finished)
        XCTAssertEqual(names, ["alpha.txt", "beta.txt", "sub"])
    }

    /// A missing directory ends the stream cleanly (finished or failed), never hangs.
    func testMissingDirectoryDoesNotHang() async {
        let fs = LocalFileSystem()
        let missing = URL(fileURLWithPath: "/nope-\(UUID().uuidString)")
        for await _ in fs.list(missing) {}
        // Reaching here proves the stream terminated rather than hanging.
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yafm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
