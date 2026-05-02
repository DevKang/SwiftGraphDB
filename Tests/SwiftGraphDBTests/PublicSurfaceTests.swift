// IMPORTANT: this file deliberately does NOT use @testable or @_spi imports. It exists to
// prove the documented public surface of SPEC §12 compiles and is callable from app code.
// Adding `@testable` here defeats the purpose.
import XCTest
import SwiftGraphDB

final class PublicSurfaceTests: XCTestCase {

    // MARK: - Core read/write API

    func testCoreCRUDIsPublic() async throws {
        let store = try await GraphStore.openInMemory()
        let alice = try await store.addNode(label: "Person", properties: ["name": "Alice", "age": .int(30)])
        let bob = try await store.addNode(label: "Person", properties: ["name": "Bob"])
        _ = try await store.addEdge(from: alice, to: bob, type: "KNOWS", properties: [:])
        try await store.updateNode(id: alice, properties: ["name": "Alice2"])
        try await store.deleteEdge(id: bob)  // safe: nothing to delete with this id but call signature exists
        try await store.deleteNode(id: bob)
        await store.close()
    }

    func testQueryAPIIsPublic() async throws {
        let store = try await GraphStore.openInMemory()
        _ = try await store.addNode(label: "Person", properties: ["age": .int(40)])

        let allPersons: NodeQuery = await store.nodes(labeled: "Person")
        let olderThan30: NodeQuery = await store.nodes(where: "age", greaterThan: .int(30))
        let result1 = try await allPersons.collect()
        let result2 = try await olderThan30.collect()
        XCTAssertGreaterThanOrEqual(result1.count, 1)
        XCTAssertGreaterThanOrEqual(result2.count, 1)
        // Other public terminal operations.
        _ = try await allPersons.count()
        _ = try await allPersons.first()
        _ = try await allPersons.exists()
        await store.close()
    }

    // MARK: - Sync API (M8 surface)

    func testSyncAPIIsPublic() async throws {
        let store = try await GraphStore.openInMemory()
        let backend = InMemorySyncBackend()
        let id = SyncBackendID("public-surface-test")
        let transport = await backend.transport(for: id)
        try await store.enableSync(transport: transport, resolver: FieldLevelMergeResolver())

        // syncStatus is a public AsyncStream (an async-accessor property on the actor wrapper).
        _ = await store.syncStatus

        // syncNow / disableSync are part of the public surface.
        _ = try await store.syncNow(backendID: id)
        await store.disableSync(backendID: id)
        await store.close()
    }

    func testSyncProtocolValueTypesArePublic() throws {
        // Documented sync types from SPEC §12. Constructing them proves they compile from
        // app code without @testable.
        let actor = ActorID()
        let revision = GraphRevision(actorID: actor, counter: 1, wallClock: Date())
        let entity = GraphEntityRef(kind: .node, id: UUID())
        let payload = GraphRecordPayload(properties: ["x": .int(1)], label: "P")
        let change = GraphChange(
            id: UUID(), graphID: UUID(), actorID: actor, sequence: 1,
            entity: entity, operation: .upsert, payload: payload,
            baseRevision: nil, revision: revision, createdAt: Date()
        )
        let batch = ChangeBatch(graphID: UUID(), backendID: SyncBackendID("d"), changes: [change], highWatermark: 0)
        XCTAssertEqual(batch.changes.first?.id, change.id)

        // Conflict resolvers shipped in core.
        _ = LocalWinsResolver()
        _ = RemoteWinsResolver()
        _ = FieldLevelMergeResolver()

        // Resolution + Conflict types.
        let conflict = GraphConflict(
            backendID: SyncBackendID("d"),
            entity: entity,
            base: nil,
            local: payload,
            remote: payload
        )
        XCTAssertEqual(conflict.entity.id, entity.id)
        let resolution: GraphConflictResolution = .useRemote
        if case .useRemote = resolution {} else { XCTFail() }
    }

    // MARK: - Property values

    func testPropertyValueLiteralsArePublic() {
        let s: PropertyValue = "hello"
        let i: PropertyValue = .int(42)
        let d: PropertyValue = .double(3.14)
        let b: PropertyValue = .bool(true)
        XCTAssertEqual(s, "hello")
        XCTAssertEqual(i, .int(42))
        XCTAssertEqual(d, .double(3.14))
        XCTAssertEqual(b, .bool(true))
    }
}
