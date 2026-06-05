import Foundation
import XCTest
@testable import Core

final class _DLPerf: XCTestCase {
    func testDownloadsRelease() async {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let fs = LocalFileSystem()
        let t0 = Date()
        var all: [FSEntry] = []
        for await ev in fs.list(dir) { if case .entries(let b) = ev { all.append(contentsOf: b) } }
        let listMs = Date().timeIntervalSince(t0) * 1000
        let t1 = Date()
        _ = all.sorted(by: SortOrder(key: .name, ascending: true))
        let sortMs = Date().timeIntervalSince(t1) * 1000
        print(String(format: "DLPERF count=%d list=%.1fms sort=%.1fms", all.count, listMs, sortMs))
    }
}
