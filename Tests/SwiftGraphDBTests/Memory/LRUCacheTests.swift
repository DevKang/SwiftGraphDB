import XCTest
@testable import SwiftGraphDB

final class LRUCacheTests: XCTestCase {

    func testEvictsOldestWhenOverCapacity() {
        var cache = LRUCache<Int, String>(capacity: 3)
        cache.put(1, "one")
        cache.put(2, "two")
        cache.put(3, "three")
        cache.put(4, "four") // evicts 1

        XCTAssertNil(cache.get(1))
        XCTAssertEqual(cache.get(2), "two")
        XCTAssertEqual(cache.get(3), "three")
        XCTAssertEqual(cache.get(4), "four")
    }

    func testGetMovesEntryToFrontAndPreventsEviction() {
        var cache = LRUCache<Int, String>(capacity: 3)
        cache.put(1, "one")
        cache.put(2, "two")
        cache.put(3, "three")
        _ = cache.get(1)         // 1 is now MRU
        cache.put(4, "four")     // evicts 2 (LRU), not 1

        XCTAssertEqual(cache.get(1), "one")
        XCTAssertNil(cache.get(2))
        XCTAssertEqual(cache.get(3), "three")
        XCTAssertEqual(cache.get(4), "four")
    }

    func testRemoveDetachesEntry() {
        var cache = LRUCache<Int, String>(capacity: 3)
        cache.put(1, "one")
        cache.put(2, "two")
        cache.remove(1)
        XCTAssertNil(cache.get(1))
        XCTAssertEqual(cache.count, 1)
    }

    func testReputUpdatesValueAndRecency() {
        var cache = LRUCache<Int, String>(capacity: 2)
        cache.put(1, "one")
        cache.put(2, "two")
        cache.put(1, "ONE")     // updates AND moves to front
        cache.put(3, "three")   // evicts 2

        XCTAssertEqual(cache.get(1), "ONE")
        XCTAssertNil(cache.get(2))
        XCTAssertEqual(cache.get(3), "three")
    }

    func testRemoveAllClears() {
        var cache = LRUCache<Int, String>(capacity: 5)
        cache.put(1, "x"); cache.put(2, "y")
        cache.removeAll()
        XCTAssertTrue(cache.isEmpty)
        XCTAssertNil(cache.get(1))
    }

    /// Sanity perf check — 100K reads on a 10K-entry cache should hit > 95% (Zipf-ish workload).
    func testHotKeyHitRateOnRandomWorkload() {
        var cache = LRUCache<Int, Int>(capacity: 10_000)
        var hits = 0
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<100_000 {
            // Skewed toward the first 10K keys.
            let k = Int(abs(Int(truncatingIfNeeded: rng.next())) % 10_000)
            if cache.get(k) != nil { hits += 1 } else { cache.put(k, k) }
        }
        // 100K accesses over 10K-entry domain with capacity = 10K: cold-start fills the
        // cache in the first ~10K hits; subsequent ~90K are mostly hits. Allowing a 1%
        // safety margin around the warm-up boundary.
        XCTAssertGreaterThan(hits, 85_000, "expected > 85% hit rate on hot 10K-key set")
    }
}
