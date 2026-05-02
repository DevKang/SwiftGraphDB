import XCTest
@testable import SwiftGraphDB
@testable import SwiftGraphDBCloudKit

final class CloudKitContractTests: XCTestCase {

    // The core sync contract from M8 (`GraphSyncContract<Transport>`) parametrised over a
    // `CloudKitGraphSyncTransport` that is talking to a `SharedMockCloudKitBackend`. Adding a
    // new contract assertion in M8 is automatically exercised here without code changes.

    private func buildContract() -> GraphSyncContract<CloudKitGraphSyncTransport> {
        let backend = SharedMockCloudKitBackend()
        return GraphSyncContract<CloudKitGraphSyncTransport> {
            let device = SyncBackendID(UUID().uuidString)
            let client = SharedMockCloudKitClient(backend: backend)
            let transport = CloudKitGraphSyncTransport(backendID: device, database: client)
            return (transport, {})
        }
    }

    func testRoundTrip() async throws {
        try await buildContract().runRoundTrip(actorIDA: UUID(), actorIDB: UUID())
    }

    func testIdempotentRePush() async throws {
        try await buildContract().runIdempotentRePush(actorID: UUID())
    }

    func testCheckpointResume() async throws {
        try await buildContract().runCheckpointResume(actorIDA: UUID(), actorIDB: UUID())
    }

    /// SPEC §16.4 — two devices edit different fields of the same node. After a full sync
    /// round both fields are present. Routed through `RecordCodec` + the CloudKit transport.
    func testTwoDeviceConvergenceThroughCloudKit() async throws {
        let backend = SharedMockCloudKitBackend()
        let storeA = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: storeA)
        let actorA = await GraphActor(store: storeA)

        let storeB = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: storeB)
        let actorB = await GraphActor(store: storeB)

        let aBackendID = SyncBackendID(try meta(storeA, key: "actor_id")!)
        let bBackendID = SyncBackendID(try meta(storeB, key: "actor_id")!)
        let transportA = CloudKitGraphSyncTransport(
            backendID: aBackendID,
            database: SharedMockCloudKitClient(backend: backend)
        )
        let transportB = CloudKitGraphSyncTransport(
            backendID: bBackendID,
            database: SharedMockCloudKitClient(backend: backend)
        )

        let resolver = FieldLevelMergeResolver()
        let coordA = SyncCoordinator(graph: actorA, transport: transportA, resolver: resolver)
        let coordB = SyncCoordinator(graph: actorB, transport: transportB, resolver: resolver)

        // Device A creates the node, syncs.
        let aliceID = try await actorA.addNode(label: "Person", properties: ["name": "Alice"])
        _ = try await coordA.runOnce()
        // B observes Alice.
        _ = try await coordB.runOnce()
        let bSeesAlice = try NodeRepository(store: storeB).fetch(id: aliceID)
        XCTAssertEqual(bSeesAlice?.properties["name"], "Alice")

        // Both devices edit different fields.
        try await actorA.updateNode(id: aliceID, properties: ["name": "Alice", "age": .int(30)])
        try await actorB.updateNode(id: aliceID, properties: ["name": "Alice", "city": "Seoul"])

        // Sync round: A pushes age, B pushes city; A pulls B's city, B pulls A's age.
        _ = try await coordA.runOnce()
        _ = try await coordB.runOnce()
        _ = try await coordA.runOnce()
        _ = try await coordB.runOnce()

        let aFinal = try NodeRepository(store: storeA).fetch(id: aliceID)
        let bFinal = try NodeRepository(store: storeB).fetch(id: aliceID)

        XCTAssertNotNil(aFinal?.properties["age"], "A should have its own age write")
        XCTAssertNotNil(aFinal?.properties["city"], "A should have B's city write")
        XCTAssertNotNil(bFinal?.properties["age"], "B should have A's age write")
        XCTAssertNotNil(bFinal?.properties["city"], "B should have its own city write")
    }

    /// Property BLOBs round-trip byte-for-byte through CloudKit serialisation.
    func testRecordCodecBLOBIsByteForByteIdentical() throws {
        let id = UUID()
        let actor = ActorID()
        let payload = GraphRecordPayload(
            properties: ["a": .int(1), "b": "two", "c": .double(3.14)],
            label: "P"
        )
        let original = GraphChange(
            id: UUID(), graphID: UUID(), actorID: actor,
            sequence: 1,
            entity: GraphEntityRef(kind: .node, id: id),
            operation: .upsert,
            payload: payload,
            baseRevision: nil,
            revision: GraphRevision(actorID: actor, counter: 1, wallClock: Date()),
            createdAt: Date()
        )
        let record = try RecordCodec.encode(original)
        let decoded = try RecordCodec.decode(record)
        XCTAssertEqual(decoded.payload, original.payload)
        XCTAssertEqual(decoded, original)
    }

    private func meta(_ store: SQLiteStore, key: String) throws -> String? {
        try store.query("SELECT value FROM db_meta WHERE key = ?", [.text(key)]) { $0.text(at: 0) }
            .first.flatMap { $0 }
    }
}
