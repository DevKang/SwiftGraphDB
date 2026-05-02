import XCTest
@testable import SwiftGraphDB

final class InMemoryContractTests: XCTestCase {

    // SPEC §16.3 line items, each backed by a contract assertion. The InMemorySyncBackend
    // is the canonical reference; future adapters reuse the same parametrised harness.

    private func buildContract() -> (GraphSyncContract<InMemorySyncTransport>, @Sendable () async -> Void) {
        let backend = InMemorySyncBackend()
        let contract = GraphSyncContract<InMemorySyncTransport> {
            let device = SyncBackendID(UUID().uuidString)
            let transport = await backend.transport(for: device)
            return (transport, {})
        }
        let teardown: @Sendable () async -> Void = {}
        return (contract, teardown)
    }

    func testRoundTrip() async throws {
        let (contract, _) = buildContract()
        try await contract.runRoundTrip(actorIDA: UUID(), actorIDB: UUID())
    }

    func testIdempotentRePush() async throws {
        let (contract, _) = buildContract()
        try await contract.runIdempotentRePush(actorID: UUID())
    }

    func testCheckpointResume() async throws {
        let (contract, _) = buildContract()
        try await contract.runCheckpointResume(actorIDA: UUID(), actorIDB: UUID())
    }

    /// Multi-device convergence on top of the contract surface.
    func testTwoDeviceConvergenceViaContract() async throws {
        let backend = InMemorySyncBackend()
        let storeA = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: storeA)
        let actorA = await GraphActor(store: storeA)

        let storeB = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: storeB)
        let actorB = await GraphActor(store: storeB)

        let aBackendID = SyncBackendID(try await meta(storeA, key: "actor_id")!)
        let bBackendID = SyncBackendID(try await meta(storeB, key: "actor_id")!)
        let transportA = await backend.transport(for: aBackendID)
        let transportB = await backend.transport(for: bBackendID)

        let resolver = FieldLevelMergeResolver()
        let coordA = SyncCoordinator(graph: actorA, transport: transportA, resolver: resolver)
        let coordB = SyncCoordinator(graph: actorB, transport: transportB, resolver: resolver)

        let aliceID = try await actorA.addNode(label: "Person", properties: ["name": "Alice"])
        _ = try await coordA.runOnce()
        _ = try await coordB.runOnce()
        let bView = try NodeRepository(store: storeB).fetch(id: aliceID)
        XCTAssertEqual(bView?.properties["name"], "Alice")
    }

    private func meta(_ store: SQLiteStore, key: String) throws -> String? {
        try store.query("SELECT value FROM db_meta WHERE key = ?", [.text(key)]) { $0.text(at: 0) }
            .first.flatMap { $0 }
    }
}
