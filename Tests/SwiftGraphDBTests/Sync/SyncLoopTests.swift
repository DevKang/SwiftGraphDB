import XCTest
@testable import SwiftGraphDB

final class SyncLoopTests: XCTestCase {

    private func makeActor() async throws -> (GraphActor, SQLiteStore) {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        let actor = await GraphActor(store: store)
        return (actor, store)
    }

    func testPushThenPullSingleDeviceRoundTrip() async throws {
        let (actor, store) = try await makeActor()
        let backend = InMemorySyncBackend()
        let actorID = try await meta(store, key: "actor_id")!
        let device = SyncBackendID(actorID)
        let transport = await backend.transport(for: device)

        _ = try await actor.addNode(label: "P", properties: ["x": .int(1)])

        let coordinator = SyncCoordinator(
            graph: actor, transport: transport, resolver: FieldLevelMergeResolver()
        )
        let result = try await coordinator.runOnce()
        XCTAssertEqual(result.pushed, 1)
        // Pull on the same device sees nothing (the change was authored here).
        XCTAssertEqual(result.applied, 0)

        let metadata = SyncMetadataStore(store: store)
        let (cp, hwm) = try metadata.loadCheckpoint(backendID: device)
        XCTAssertNotNil(cp)
        XCTAssertGreaterThan(hwm, 0)
    }

    func testTwoDeviceConvergence() async throws {
        // Device A and Device B share an InMemorySyncBackend. A creates a node, syncs;
        // B syncs and observes the node.
        let backend = InMemorySyncBackend()

        let (actorA, storeA) = try await makeActor()
        let (actorB, storeB) = try await makeActor()
        let aID = SyncBackendID(try await meta(storeA, key: "actor_id")!)
        let bID = SyncBackendID(try await meta(storeB, key: "actor_id")!)
        let transportA = await backend.transport(for: aID)
        let transportB = await backend.transport(for: bID)

        let resolver = FieldLevelMergeResolver()
        let coordA = SyncCoordinator(graph: actorA, transport: transportA, resolver: resolver)
        let coordB = SyncCoordinator(graph: actorB, transport: transportB, resolver: resolver)

        let aliceID = try await actorA.addNode(label: "Person", properties: ["name": "Alice"])
        _ = try await coordA.runOnce()      // push A's change
        _ = try await coordB.runOnce()      // pull on B

        let nodes = NodeRepository(store: storeB)
        let observed = try nodes.fetch(id: aliceID)
        XCTAssertEqual(observed?.properties["name"], "Alice")
    }

    func testCrashRecoveryIdempotency() async throws {
        let (actor, store) = try await makeActor()
        let backend = InMemorySyncBackend()
        let device = SyncBackendID(try await meta(store, key: "actor_id")!)
        let transport = await backend.transport(for: device)

        for _ in 0..<3 { _ = try await actor.addNode(label: "P", properties: [:]) }
        let coord = SyncCoordinator(graph: actor, transport: transport, resolver: FieldLevelMergeResolver())
        _ = try await coord.runOnce()

        // Crash + re-run: every previously-accepted change is re-pushed but the backend
        // dedupes by changeID; net effect should be no new changes.
        _ = try await coord.runOnce()
        let count = await backend.changeCount
        XCTAssertEqual(count, 3)
    }

    private func meta(_ store: SQLiteStore, key: String) throws -> String? {
        try store.query("SELECT value FROM db_meta WHERE key = ?", [.text(key)]) { $0.text(at: 0) }
            .first.flatMap { $0 }
    }
}
