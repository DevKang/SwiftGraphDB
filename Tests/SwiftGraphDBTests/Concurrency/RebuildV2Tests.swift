import XCTest
@testable import SwiftGraphDB

final class RebuildV2Tests: XCTestCase {

    private func openStore() throws -> SQLiteStore {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        return store
    }

    // MARK: - nextCounterForLocalActor

    func testNextCounterIs1OnFreshStore() throws {
        let store = try openStore()
        defer { store.close() }
        let result = try RebuildFromSQLite.rebuild(store: store, propertyIndexSpecs: [])
        XCTAssertEqual(result.nextCounterForLocalActor, 1)
    }

    func testNextCounterAfter100ActorWritesIs101() async throws {
        let store = try openStore()
        let actor = await GraphActor(store: store, propertyIndexSpecs: [])
        for _ in 0..<100 {
            _ = try await actor.addNode(label: "P", properties: [:])
        }
        let result = try RebuildFromSQLite.rebuild(store: store, propertyIndexSpecs: [])
        XCTAssertEqual(result.nextCounterForLocalActor, 101)
        store.close()
    }

    func testV1BackfilledStoreReturnsNextCounter1() throws {
        // Run only migration #1 to build a v1 store, seed a row, then upgrade.
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }
        try MigrationRunner(migrations: [MigrationRunner.defaultMigrations[0]]).run(on: store)
        let id = UUID().uuidString
        try store.execute("""
        INSERT INTO nodes (id, label, properties, created_at, modified_at, is_deleted)
        VALUES (?, 'Person', x'7b7d', 1700000000.0, 1700000000.0, 0)
        """, [.text(id)])
        try MigrationRunner.runDefault(on: store) // backfill assigns counter = 0

        let result = try RebuildFromSQLite.rebuild(store: store, propertyIndexSpecs: [])
        XCTAssertEqual(result.nextCounterForLocalActor, 1, "backfilled counter 0 → next = 1")
    }

    // MARK: - Rebuilt entity revision matches last write

    func testRebuiltNodeRevisionMatchesLastActorWrite() async throws {
        let store = try openStore()
        let actor = await GraphActor(store: store, propertyIndexSpecs: [])
        let id = try await actor.addNode(label: "Person", properties: ["name": "Alice"])
        try await actor.updateNode(id: id, properties: ["name": "Alice2"])

        let nodes = NodeRepository(store: store)
        let beforeReopen = try nodes.fetch(id: id)!.revision
        XCTAssertEqual(beforeReopen.counter, 2, "addNode + updateNode → counter 2")

        // Simulate cold open: rebuild, then verify the node's revision via repo.
        _ = try RebuildFromSQLite.rebuild(store: store, propertyIndexSpecs: [])
        let after = try nodes.fetch(id: id)!.revision
        XCTAssertEqual(after, beforeReopen)
        store.close()
    }

    // MARK: - GraphActor honours nextCounterForLocalActor on hydrate

    func testActorHydratedFromRebuildContinuesCounter() async throws {
        let store = try openStore()
        defer { store.close() }
        let actor = await GraphActor(store: store, propertyIndexSpecs: [])
        for _ in 0..<3 { _ = try await actor.addNode(label: "P", properties: [:]) }

        // Hydrate a fresh actor from the rebuild result and write again. Counter must continue.
        let result = try RebuildFromSQLite.rebuild(store: store, propertyIndexSpecs: [])
        let actor2 = await GraphActor(store: store, propertyIndexSpecs: [])
        await actor2.loadRebuildResult(result)
        let id = try await actor2.addNode(label: "P", properties: [:])

        let row = try ChangeJournalStore(store: store).latestRow(forEntity: .node, id: id)!
        XCTAssertEqual(row.revision.counter, 4, "second actor continues from prior 3 → 4")
    }
}
