import XCTest
@testable import SwiftGraphDB

final class IndexMapTests: XCTestCase {

    func testInterningSameUUIDReturnsSameIndex() {
        var map = IndexMap()
        let id = IDFactory.live.nodeID()
        let first = map.intern(id)
        let second = map.intern(id)
        XCTAssertEqual(first, second)
    }

    func testInterningAssignsDenseIncreasingIndexes() {
        var map = IndexMap()
        let ids = (0..<100).map { _ in IDFactory.live.nodeID() }
        let assigned = ids.map { map.intern($0) }
        XCTAssertEqual(assigned, Array(0..<100))
    }

    func testReverseLookupReturnsOriginalUUID() {
        var map = IndexMap()
        let id = IDFactory.live.nodeID()
        let i = map.intern(id)
        XCTAssertEqual(map.nodeID(at: i), id)
    }

    func testInternalIndexForUnknownUUIDIsNil() {
        let map = IndexMap()
        XCTAssertNil(map.internalIndex(for: IDFactory.live.nodeID()))
    }

    func testNodeIDAtUnknownIndexIsNil() {
        let map = IndexMap()
        XCTAssertNil(map.nodeID(at: 0))
        XCTAssertNil(map.nodeID(at: -1))
        XCTAssertNil(map.nodeID(at: 999))
    }

    func testReleasedSlotIsReused() {
        var map = IndexMap()
        let a = IDFactory.live.nodeID()
        let b = IDFactory.live.nodeID()
        let c = IDFactory.live.nodeID()
        let i0 = map.intern(a) // 0
        let i1 = map.intern(b) // 1
        XCTAssertEqual(i0, 0); XCTAssertEqual(i1, 1)

        map.release(i0)
        XCTAssertNil(map.internalIndex(for: a))
        XCTAssertNil(map.nodeID(at: i0))

        // Newly interned id reuses the freed slot rather than allocating index 2.
        let reused = map.intern(c)
        XCTAssertEqual(reused, 0)
        XCTAssertEqual(map.nodeID(at: 0), c)
    }

    func testReleasingUnknownIndexIsNoOp() {
        var map = IndexMap()
        map.release(42) // does not crash
        let id = IDFactory.live.nodeID()
        XCTAssertEqual(map.intern(id), 0)
    }

    func testReserveCapacityAcceptsLargeHint() {
        var map = IndexMap()
        map.reserveCapacity(50_000)
        // Functional behaviour unchanged.
        let id = IDFactory.live.nodeID()
        XCTAssertEqual(map.intern(id), 0)
    }

    func testInterning100KIDsCompletesUnder100ms() {
        var map = IndexMap()
        map.reserveCapacity(100_000)
        let ids = (0..<100_000).map { _ in IDFactory.live.nodeID() }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for id in ids { _ = map.intern(id) }
        }
        XCTAssertLessThan(elapsed, .milliseconds(100), "100K interns took \(elapsed)")
    }
}
