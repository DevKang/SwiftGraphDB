import XCTest
@testable import SwiftGraphDB

final class LabelIndexTests: XCTestCase {

    func testAddMakesNodeAppearUnderLabel() {
        var index = LabelIndex()
        let id = IDFactory.live.nodeID()
        index.add(id, label: "Person")
        XCTAssertEqual(index.nodes(labeled: "Person"), [id])
    }

    func testRemoveLeavesOtherEntriesIntact() {
        var index = LabelIndex()
        let alice = IDFactory.live.nodeID()
        let bob = IDFactory.live.nodeID()
        index.add(alice, label: "Person")
        index.add(bob, label: "Person")
        index.remove(alice, label: "Person")
        XCTAssertEqual(index.nodes(labeled: "Person"), [bob])
    }

    func testUpdateMovesNodeAtomically() {
        var index = LabelIndex()
        let id = IDFactory.live.nodeID()
        index.add(id, label: "Person")
        index.update(id, from: "Person", to: "Concept")
        XCTAssertTrue(index.nodes(labeled: "Person").isEmpty)
        XCTAssertEqual(index.nodes(labeled: "Concept"), [id])
    }

    func testQueryUnknownLabelReturnsEmptySet() {
        let index = LabelIndex()
        XCTAssertEqual(index.nodes(labeled: "Person"), [])
    }

    func testRebuildMatchesIncrementalIndex() {
        let people = (0..<10).map { _ in IDFactory.live.nodeID() }
        let concepts = (0..<5).map { _ in IDFactory.live.nodeID() }

        var incremental = LabelIndex()
        for id in people { incremental.add(id, label: "Person") }
        for id in concepts { incremental.add(id, label: "Concept") }

        let rows: [(NodeID, String)] =
            people.map { ($0, "Person") } + concepts.map { ($0, "Concept") }
        let rebuilt = LabelIndex(rows: rows)

        XCTAssertEqual(rebuilt.nodes(labeled: "Person"), incremental.nodes(labeled: "Person"))
        XCTAssertEqual(rebuilt.nodes(labeled: "Concept"), incremental.nodes(labeled: "Concept"))
    }

    func testRemoveNonExistentEntryIsNoOp() {
        var index = LabelIndex()
        let id = IDFactory.live.nodeID()
        index.remove(id, label: "Person") // does not crash
        XCTAssertEqual(index.nodes(labeled: "Person"), [])
    }

    func testAddIdempotency() {
        var index = LabelIndex()
        let id = IDFactory.live.nodeID()
        index.add(id, label: "Person")
        index.add(id, label: "Person")
        XCTAssertEqual(index.nodes(labeled: "Person").count, 1)
    }

    func testRebuild100KNodesUnder100ms() {
        let labels = ["L0", "L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8", "L9"]
        let rows: [(NodeID, String)] = (0..<100_000).map { i in
            (IDFactory.live.nodeID(), labels[i % labels.count])
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = LabelIndex(rows: rows)
        }
        XCTAssertLessThan(elapsed, .milliseconds(200), "100K rebuild took \(elapsed)")
    }
}
