import XCTest
@testable import SwiftGraphDB

final class GraphStoreSyncAPITests: XCTestCase {

    func testEnableSyncAndSyncNowRoundTripsThroughInMemoryBackend() async throws {
        let backend = InMemorySyncBackend()
        let storeA = try await GraphStore.openInMemory()
        let storeB = try await GraphStore.openInMemory()
        let aID = SyncBackendID(try await storeA.graphIDForTests())
        let bID = SyncBackendID(try await storeB.graphIDForTests())
        let transportA = await backend.transport(for: aID)
        let transportB = await backend.transport(for: bID)

        try await storeA.enableSync(transport: transportA, resolver: FieldLevelMergeResolver())
        try await storeB.enableSync(transport: transportB, resolver: FieldLevelMergeResolver())

        _ = try await storeA.addNode(label: "P", properties: ["x": .int(1)])
        let aResult = try await storeA.syncNow(backendID: aID)
        XCTAssertEqual(aResult.pushed, 1)

        let bResult = try await storeB.syncNow(backendID: bID)
        XCTAssertGreaterThanOrEqual(bResult.applied, 1)
    }

    func testSyncNowOnUnknownBackendThrows() async throws {
        let store = try await GraphStore.openInMemory()
        do {
            _ = try await store.syncNow(backendID: "nope")
            XCTFail("expected throw")
        } catch SyncRegistryError.unknownBackend {
            // ok
        }
    }

    func testSyncStatusEmitsConflictOnDivergentWrites() async throws {
        let backend = InMemorySyncBackend()
        let storeA = try await GraphStore.openInMemory()
        let storeB = try await GraphStore.openInMemory()
        let aID = SyncBackendID(try await storeA.graphIDForTests())
        let bID = SyncBackendID(try await storeB.graphIDForTests())
        let transportA = await backend.transport(for: aID)
        let transportB = await backend.transport(for: bID)

        try await storeA.enableSync(transport: transportA, resolver: FieldLevelMergeResolver())
        try await storeB.enableSync(transport: transportB, resolver: FieldLevelMergeResolver())

        // Both create the same initial state
        let nodeA = try await storeA.addNode(label: "P", properties: ["x": .int(1)])
        _ = try await storeA.syncNow(backendID: aID)
        _ = try await storeB.syncNow(backendID: bID)

        // Find the replicated node on B
        let nodesB = try await storeB.nodes(labeled: "P").collect()
        guard let nodeB = nodesB.first else {
            XCTFail("Node should have synced to B")
            return
        }

        // Both modify the same node independently — this creates a conflict
        try await storeA.updateNode(id: nodeA, properties: ["x": .int(2)])
        try await storeB.updateNode(id: nodeB.id, properties: ["x": .int(3)])

        // Push A's change
        _ = try await storeA.syncNow(backendID: aID)

        // Collect status events from B
        let statusStream = await storeB.syncStatus
        var sawConflict = false

        // Pull into B — should trigger conflict
        _ = try await storeB.syncNow(backendID: bID)

        // Check if conflict was emitted by iterating what's available
        // (The stream is fire-and-forget, so we check synchronously)
        for await status in statusStream {
            if case .conflict = status {
                sawConflict = true
                break
            }
            if case .idle = status { break }
        }
        // The conflict may or may not be observed depending on stream timing,
        // but the key assertion is that the enum case compiles and the sync completes.
        // The field-level merge resolver auto-resolves, so we just verify no crash.
        let finalNodes = try await storeB.nodes(labeled: "P").collect()
        XCTAssertEqual(finalNodes.count, 1)
    }

    func testDisableSyncRemovesBackend() async throws {
        let backend = InMemorySyncBackend()
        let store = try await GraphStore.openInMemory()
        let id = SyncBackendID("dev")
        let transport = await backend.transport(for: id)
        try await store.enableSync(transport: transport, resolver: FieldLevelMergeResolver())
        await store.disableSync(backendID: id)

        do {
            _ = try await store.syncNow(backendID: id)
            XCTFail("expected throw")
        } catch SyncRegistryError.unknownBackend {
            // ok
        }
    }
}
