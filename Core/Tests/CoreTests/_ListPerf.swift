import Foundation
import XCTest
@testable import Core

final class _ListPerf: XCTestCase {
    func testRealListing8000() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<8000 { try Data().write(to: dir.appendingPathComponent("file_\(i).txt")) }

        let fs = LocalFileSystem()
        let t0 = Date()
        var all: [FSEntry] = []
        for await ev in fs.list(dir) { if case .entries(let b) = ev { all.append(contentsOf: b) } }
        let listMs = Date().timeIntervalSince(t0) * 1000
        let t1 = Date()
        _ = all.sorted(by: SortOrder(key: .name, ascending: true))
        let sortMs = Date().timeIntervalSince(t1) * 1000
        print(String(format: "LISTPERF count=%d  list=%.0fms  sort-once=%.0fms", all.count, listMs, sortMs))
    }
}
