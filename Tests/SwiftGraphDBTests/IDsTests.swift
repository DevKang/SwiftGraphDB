import XCTest
@testable import SwiftGraphDB

final class IDsTests: XCTestCase {

    // MARK: - Type-level checks (compile-time)

    func testNodeIDIsUUID() {
        let _: UUID = NodeID()
        let _: NodeID = UUID()
    }

    func testEdgeIDIsUUID() {
        let _: UUID = EdgeID()
        let _: NodeID = UUID()
    }

    // MARK: - Factory: distinctness

    func testFactoryReturnsDistinctNodeIDs() {
        var seen = Set<NodeID>()
        for _ in 0..<1_000 {
            seen.insert(IDFactory.live.nodeID())
        }
        XCTAssertEqual(seen.count, 1_000)
    }

    func testFactoryReturnsDistinctEdgeIDs() {
        var seen = Set<EdgeID>()
        for _ in 0..<1_000 {
            seen.insert(IDFactory.live.edgeID())
        }
        XCTAssertEqual(seen.count, 1_000)
    }

    // MARK: - Codable round-trip

    func testNodeIDRoundTripsThroughJSON() throws {
        let original = IDFactory.live.nodeID()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NodeID.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testEdgeIDRoundTripsThroughJSON() throws {
        let original = IDFactory.live.edgeID()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EdgeID.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Sendable (compile-time)

    func testNodeIDIsSendable() async {
        let id: NodeID = IDFactory.live.nodeID()
        let task = Task { @Sendable in id }
        let observed = await task.value
        XCTAssertEqual(observed, id)
    }

    // MARK: - Deterministic factory injection

    func testDeterministicFactoryProducesStableSequence() {
        let a = IDFactory.deterministic(seed: 42)
        let b = IDFactory.deterministic(seed: 42)
        for _ in 0..<10 {
            XCTAssertEqual(a.nodeID(), b.nodeID())
            XCTAssertEqual(a.edgeID(), b.edgeID())
        }
    }

    func testDifferentSeedsDiverge() {
        let a = IDFactory.deterministic(seed: 1)
        let b = IDFactory.deterministic(seed: 2)
        XCTAssertNotEqual(a.nodeID(), b.nodeID())
    }

    func testDeterministicFactoryStillProducesDistinctIDsWithinASeed() {
        let f = IDFactory.deterministic(seed: 99)
        var seen = Set<NodeID>()
        for _ in 0..<100 { seen.insert(f.nodeID()) }
        XCTAssertEqual(seen.count, 100)
    }
}
