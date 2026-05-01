import XCTest
@testable import SwiftGraphDB

final class TopologySnapshotTests: XCTestCase {

    private func makeActor() async throws -> GraphActor {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        return await GraphActor(store: store, propertyIndexSpecs: [])
    }

    // MARK: - Snapshot is a stable, immutable view

    func testSnapshotTakenBeforeWriteDoesNotReflectIt() async throws {
        let actor = try await makeActor()
        let alice = try await actor.addNode(label: "Person", properties: ["name": "Alice"])
        let early = await actor.snapshotTopology()

        let bob = try await actor.addNode(label: "Person", properties: ["name": "Bob"])

        XCTAssertNotNil(early.indexMap.internalIndex(for: alice))
        XCTAssertNil(early.indexMap.internalIndex(for: bob),
                     "snapshot is frozen at capture time; later writes are invisible")

        let later = await actor.snapshotTopology()
        XCTAssertNotNil(later.indexMap.internalIndex(for: bob))
    }

    // MARK: - Snapshots are Sendable across detached tasks

    func testSnapshotIsReadableInDetachedTask() async throws {
        let actor = try await makeActor()
        _ = try await actor.addNode(label: "Person", properties: [:])
        let snapshot = await actor.snapshotTopology()

        let count = await Task.detached { snapshot.labelIndex.nodes(labeled: "Person").count }.value
        XCTAssertEqual(count, 1)
    }

    // MARK: - Two snapshots at the same actor instant are equal in topology

    func testTwoSnapshotsAtSameInstantHaveEqualTopology() async throws {
        let actor = try await makeActor()
        for _ in 0..<5 { _ = try await actor.addNode(label: "Person", properties: [:]) }
        let a = await actor.snapshotTopology()
        let b = await actor.snapshotTopology()
        XCTAssertEqual(a.indexMap.count, b.indexMap.count)
        XCTAssertEqual(a.forward.edges.count, b.forward.edges.count)
        XCTAssertEqual(a.edgeLog.size, b.edgeLog.size)
    }

    // MARK: - EdgeLog frozen at snapshot capture

    func testEdgeLogSizeAtSnapshotMatchesWritesSoFar() async throws {
        let actor = try await makeActor()
        let from = try await actor.addNode(label: "Person", properties: [:])
        let to = try await actor.addNode(label: "Person", properties: [:])

        let before = await actor.snapshotTopology()
        XCTAssertEqual(before.edgeLog.size, 0)

        for _ in 0..<10 {
            _ = try await actor.addEdge(from: from, to: to, type: "L", properties: [:])
        }

        let after = await actor.snapshotTopology()
        XCTAssertEqual(after.edgeLog.size, 10)
        XCTAssertEqual(before.edgeLog.size, 0, "earlier snapshot must remain frozen")
    }

    // MARK: - Read-only traversal driver runs off-actor

    func testTraversalDriverWorksOffActor() async throws {
        let actor = try await makeActor()
        let from = try await actor.addNode(label: "Person", properties: [:])
        let to = try await actor.addNode(label: "Person", properties: [:])
        _ = try await actor.addEdge(from: from, to: to, type: "L", properties: [:])

        let snapshot = await actor.snapshotTopology()

        // Walk neighbours from the snapshot in a Task.detached. No actor isolation issues
        // should arise because TopologySnapshot is fully Sendable.
        let count = await Task.detached {
            let i = snapshot.indexMap.internalIndex(for: from)!
            let merged = EdgeLog.merge(
                csrEdges: snapshot.forward.neighbours(of: i),
                logEntries: snapshot.edgeLog.outgoingEntries(from: from)
            )
            return merged.count
        }.value
        XCTAssertEqual(count, 1)
    }
}
