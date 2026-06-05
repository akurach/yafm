import Foundation
import XCTest
@testable import Core

/// Covers the v0.5 async-value seam on `PluginColumn` + `PluginValueCache`: a
/// sync column stays exactly as in v0.3/v0.4, while an async column renders a
/// placeholder first and resolves off the critical path through the cache.
@MainActor
final class PluginColumnTests: XCTestCase {

    private func entry(_ name: String) -> FSEntry {
        FSEntry(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
                isDirectory: false, isHidden: false, size: nil, modified: nil)
    }

    // MARK: Back-compat — the synchronous contract is untouched

    func testSyncColumnReturnsValueDirectly() {
        let col = PluginColumn(id: "x.sync", title: "Sync") { .text($0.name.uppercased()) }
        XCTAssertFalse(col.isAsync)
        let cache = PluginValueCache()
        let v = cache.value(for: entry("readme"), in: col) { XCTFail("sync must not resolve async") }
        XCTAssertEqual(v, .text("README"))
    }

    // MARK: Async — placeholder first, resolved value after

    func testAsyncColumnShowsPlaceholderThenResolves() async {
        let col = PluginColumn(id: "x.async", title: "Async",
                               placeholder: { _ in .text("…") }) { e in
            await Task.yield()
            return .number(Double(e.name.count))
        }
        XCTAssertTrue(col.isAsync)

        let cache = PluginValueCache()
        let e = entry("hello")   // 5 chars

        // First read: placeholder, resolve kicked off.
        let resolved = expectation(description: "async resolve")
        let first = cache.value(for: e, in: col) { resolved.fulfill() }
        XCTAssertEqual(first, .text("…"))

        await fulfillment(of: [resolved], timeout: 2)

        // Second read: cached resolved value, no further resolve.
        let second = cache.value(for: e, in: col) { XCTFail("must not re-resolve a cached key") }
        XCTAssertEqual(second, .number(5))
    }

    // MARK: Dedup — concurrent reads spawn one resolve

    func testAsyncResolveIsDedupedPerKey() async {
        let counter = ResolveCounter()
        let col = PluginColumn(id: "x.dedup", title: "Dedup") { _ in
            await counter.bump()
            return .text("done")
        }
        let cache = PluginValueCache()
        let e = entry("file")

        let done = expectation(description: "resolved once")
        done.expectedFulfillmentCount = 1
        done.assertForOverFulfill = false
        // Three synchronous reads before the first resolve lands → one inflight.
        for _ in 0..<3 { _ = cache.value(for: e, in: col) { done.fulfill() } }
        await fulfillment(of: [done], timeout: 2)

        let count = await counter.value
        XCTAssertEqual(count, 1, "three reads of one key must trigger exactly one resolve")
    }

    // MARK: Invalidation clears cached values

    func testInvalidateDropsCachedValues() async {
        let col = PluginColumn(id: "x.inval", title: "Inval") { _ in
            await Task.yield(); return .text("v1")
        }
        let cache = PluginValueCache()
        let e = entry("f")

        let r = expectation(description: "first resolve")
        _ = cache.value(for: e, in: col) { r.fulfill() }
        await fulfillment(of: [r], timeout: 2)
        XCTAssertEqual(cache.value(for: e, in: col) { }, .text("v1"))

        cache.invalidate(columnID: "x.inval")
        // After invalidation the value is gone → placeholder again, re-resolves.
        XCTAssertEqual(cache.value(for: e, in: col) { }, .none)
    }
}

/// Actor tally for the dedup test.
private actor ResolveCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}
