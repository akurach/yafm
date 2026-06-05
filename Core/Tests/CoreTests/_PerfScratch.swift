import Foundation
import XCTest
@testable import Core

final class _PerfScratch: XCTestCase {
    func makeEntries(_ n: Int) -> [FSEntry] {
        (0..<n).map { i in
            FSEntry(url: URL(fileURLWithPath: "/x/file_\(String(format: "%06d", (i*7919)%n)).txt"),
                    name: "file_\(String(format: "%06d", (i*7919)%n)).txt",
                    isDirectory: i % 10 == 0, isHidden: false, size: Int64(i), modified: nil)
        }
    }
    func testStreamingSortCost() {
        let all = makeEntries(8000)
        let order = SortOrder(key: .name, ascending: true)
        // OLD: sort the whole growing partial on every 128-file batch.
        let t0 = Date()
        var partial: [FSEntry] = []
        var i = 0
        while i < all.count {
            partial.append(contentsOf: all[i..<min(i+128, all.count)])
            _ = partial.sorted(by: order)   // every batch
            i += 128
        }
        let oldMs = Date().timeIntervalSince(t0) * 1000
        // NEW: arrival order during stream, one sort at the end.
        let t1 = Date()
        _ = all.sorted(by: order)
        let newMs = Date().timeIntervalSince(t1) * 1000
        print(String(format: "PERF8000 old(sort-every-batch)=%.0fms  new(sort-once)=%.0fms  speedup=%.0fx",
                     oldMs, newMs, oldMs/max(newMs,0.001)))
    }
}
