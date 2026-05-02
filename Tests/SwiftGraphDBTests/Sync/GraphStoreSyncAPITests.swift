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
