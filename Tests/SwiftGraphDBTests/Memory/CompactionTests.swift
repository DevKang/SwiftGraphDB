import XCTest
@testable import SwiftGraphDB

final class CompactionTests: XCTestCase {

    // MARK: - Helpers

    private func emptyState(nodeCount: Int = 0) -> Compactor.State {
        Compactor.State(
            indexMap: IndexMap(),
            forward: CSRAdjacency(nodeCount: nodeCount, edges: []),
            reverse: CSRAdjacency(nodeCount: nodeCount, edges: []),
            log: EdgeLog()
        )
    }

    private func intern(_ map: inout IndexMap, _ count: Int) -> [NodeID] {
        let ids = (0..<count).map { _ in IDFactory.live.nodeID() }
        for id in ids { _ = map.intern(id) }
        return ids
    }

    // MARK: - No-op cases

    func testEmptyLogIsNoOp() {
        let state = emptyState()
        let after = Compactor.compact(state)
        XCTAssertEqual(after.log.size, 0)
        XCTAssertEqual(after.forward.edges.count, 0)
        XCTAssertEqual(after.reverse.edges.count, 0)
    }

    func testCompactingPreservesLiveEdgesExactlyOnce() {
        var indexMap = IndexMap()
        let ids = intern(&indexMap, 3)
        let edge = Edge(type: "L", fromID: ids[0], toID: ids[1])

        var log = EdgeLog()
        log.append(.init(
            edgeID: edge.id, fromID: edge.fromID, toID: edge.toID,
            type: edge.type, timestamp: Date(), operation: .insert
        ))

        let state = Compactor.State(
            indexMap: indexMap,
            forward: CSRAdjacency(nodeCount: indexMap.countIncludingFreed, edges: []),
            reverse: CSRAdjacency(nodeCount: indexMap.countIncludingFreed, edges: []),
            log: log
        )
        let after = Compactor.compact(state)

        XCTAssertEqual(after.log.size, 0)
        XCTAssertEqual(after.forward.degree(of: 0), 1)
        XCTAssertEqual(after.reverse.degree(of: 1), 1)
        XCTAssertEqual(Array(after.forward.neighbours(of: 0)).first?.edgeID, edge.id)
    }

    // MARK: - Tombstones

    func testCSREdgeShadowedByLogDeleteIsRemovedAfterCompaction() {
        var indexMap = IndexMap()
        let ids = intern(&indexMap, 2)
        let edgeID = IDFactory.live.edgeID()

        // Build CSR that already contains the edge.
        let forward = CSRAdjacency(
            nodeCount: indexMap.countIncludingFreed,
            edges: [(0, .init(toID: ids[1], edgeID: edgeID, type: "L"))]
        )
        let reverse = CSRAdjacency(
            nodeCount: indexMap.countIncludingFreed,
            edges: [(1, .init(toID: ids[0], edgeID: edgeID, type: "L"))]
        )
        var log = EdgeLog()
        log.append(.init(
            edgeID: edgeID, fromID: ids[0], toID: ids[1], type: "L",
            timestamp: Date(), operation: .delete
        ))

        let after = Compactor.compact(.init(
            indexMap: indexMap, forward: forward, reverse: reverse, log: log
        ))

        XCTAssertEqual(after.log.size, 0)
        XCTAssertEqual(after.forward.degree(of: 0), 0)
        XCTAssertEqual(after.reverse.degree(of: 1), 0)
    }

    func testInsertThenDeleteThenInsertEndsAsLiveAfterCompaction() {
        var indexMap = IndexMap()
        let ids = intern(&indexMap, 2)
        let edgeID = IDFactory.live.edgeID()

        var log = EdgeLog()
        log.append(.init(edgeID: edgeID, fromID: ids[0], toID: ids[1], type: "L",
                         timestamp: Date(), operation: .insert))
        log.append(.init(edgeID: edgeID, fromID: ids[0], toID: ids[1], type: "L",
                         timestamp: Date().addingTimeInterval(1), operation: .delete))
        log.append(.init(edgeID: edgeID, fromID: ids[0], toID: ids[1], type: "L",
                         timestamp: Date().addingTimeInterval(2), operation: .insert))

        let state = Compactor.State(
            indexMap: indexMap,
            forward: CSRAdjacency(nodeCount: indexMap.countIncludingFreed, edges: []),
            reverse: CSRAdjacency(nodeCount: indexMap.countIncludingFreed, edges: []),
            log: log
        )
        let after = Compactor.compact(state)
        XCTAssertEqual(after.forward.degree(of: 0), 1)
        XCTAssertEqual(after.forward.edges.first?.edgeID, edgeID)
    }

    // MARK: - Burst

    func testBurstOf10KInsertsThenCompact() {
        var indexMap = IndexMap()
        indexMap.reserveCapacity(2)
        let from = IDFactory.live.nodeID(); _ = indexMap.intern(from)
        let to = IDFactory.live.nodeID(); _ = indexMap.intern(to)

        var log = EdgeLog()
        for _ in 0..<10_000 {
            log.append(.init(
                edgeID: IDFactory.live.edgeID(), fromID: from, toID: to, type: "L",
                timestamp: Date(), operation: .insert
            ))
        }
        let state = Compactor.State(
            indexMap: indexMap,
            forward: CSRAdjacency(nodeCount: indexMap.countIncludingFreed, edges: []),
            reverse: CSRAdjacency(nodeCount: indexMap.countIncludingFreed, edges: []),
            log: log
        )
        let after = Compactor.compact(state)
        XCTAssertEqual(after.log.size, 0)
        XCTAssertEqual(after.forward.degree(of: 0), 10_000)
    }

    // MARK: - Snapshot consistency

    func testPreCompactionSnapshotReadsAreEqualToPostCompactionReads() {
        var indexMap = IndexMap()
        let ids = intern(&indexMap, 3)

        // Pre-state: CSR with one edge ids[0] → ids[1]; log has insert ids[0] → ids[2].
        let preexistingEdgeID = IDFactory.live.edgeID()
        let logEdgeID = IDFactory.live.edgeID()
        let forward = CSRAdjacency(
            nodeCount: indexMap.countIncludingFreed,
            edges: [(0, .init(toID: ids[1], edgeID: preexistingEdgeID, type: "L"))]
        )
        let reverse = CSRAdjacency(
            nodeCount: indexMap.countIncludingFreed,
            edges: [(1, .init(toID: ids[0], edgeID: preexistingEdgeID, type: "L"))]
        )
        var log = EdgeLog()
        log.append(.init(
            edgeID: logEdgeID, fromID: ids[0], toID: ids[2], type: "L",
            timestamp: Date(), operation: .insert
        ))

        let pre = Compactor.State(indexMap: indexMap, forward: forward, reverse: reverse, log: log)

        // Read via merge (pre-compaction snapshot).
        let preMerged = Set(EdgeLog.merge(
            csrEdges: pre.forward.neighbours(of: 0),
            logEntries: pre.log.outgoingEntries(from: ids[0])
        ).map(\.edgeID))

        // Read post-compaction.
        let post = Compactor.compact(pre)
        let postMerged = Set(EdgeLog.merge(
            csrEdges: post.forward.neighbours(of: 0),
            logEntries: post.log.outgoingEntries(from: ids[0])
        ).map(\.edgeID))

        XCTAssertEqual(preMerged, postMerged)
        XCTAssertEqual(preMerged, [preexistingEdgeID, logEdgeID])
    }

    // MARK: - Triggers

    func testShouldCompactTriggersOverThreshold() {
        var indexMap = IndexMap()
        _ = indexMap.intern(IDFactory.live.nodeID())
        var log = EdgeLog()
        let from = IDFactory.live.nodeID()
        let to = IDFactory.live.nodeID()
        for _ in 0..<5 {
            log.append(.init(edgeID: IDFactory.live.edgeID(),
                             fromID: from, toID: to, type: "L",
                             timestamp: Date(), operation: .insert))
        }
        let policy = Compactor.Policy(thresholdMultiplier: 4)
        // 1 node → threshold = 4 entries → 5 entries should trigger.
        XCTAssertTrue(policy.shouldCompact(nodeCount: 1, logSize: 5))
        XCTAssertFalse(policy.shouldCompact(nodeCount: 1, logSize: 3))
    }
}
