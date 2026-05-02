import XCTest
@_spi(Internal) @testable import SwiftGraphDB

final class SyncLoopOfflineTests: XCTestCase {

    /// Local writes during offline append to the journal; resume sync drains them.
    func testWritesDuringOfflineQueueInJournalAndDrainOnResume() async throws {
        let backend = InMemorySyncBackend()
        let store = try await GraphStore.openInMemory()
        let id = SyncBackendID("offline-tests")
        let transport = await backend.transport(for: id)
        try await store.enableSync(transport: transport, resolver: FieldLevelMergeResolver())

        // 5 writes while sync is enabled but never invoked → journal fills up.
        for _ in 0..<5 {
            _ = try await store.addNode(label: "P", properties: [:])
        }
        let journal = ChangeJournalStore(store: await store.storeForQueriesUnsafe)
        XCTAssertEqual(try journal.count(), 5)

        // First syncNow drains all 5 to the backend.
        let drain = try await store.syncNow(backendID: id)
        XCTAssertEqual(drain.pushed, 5)
    }

    func testTransientPullErrorTransitionsToOffline() async throws {
        let backend = InMemorySyncBackend()
        let store = try await GraphStore.openInMemory()
        let id = SyncBackendID("offline-tests-2")
        let transport = await backend.transport(for: id)
        try await store.enableSync(transport: transport, resolver: FieldLevelMergeResolver())

        // Trigger a transient pull failure. The first call to syncNow should throw and
        // transition status to .offline.
        await backend.setFailureMode(.nextPullTransient)

        // Status stream is multiplexed; collect events asynchronously.
        let statusStream = await store.syncStatus
        var iter = statusStream.makeAsyncIterator()
        let collector = Task<[SyncStatus], Never> {
            var events: [SyncStatus] = []
            for _ in 0..<3 {
                if let event = await iter.next() { events.append(event) } else { break }
            }
            return events
        }

        do {
            _ = try await store.syncNow(backendID: id)
            XCTFail("expected throw")
        } catch InMemorySyncError.injectedTransient {
            // ok
        }

        // Give the registry a tick to publish status events.
        try await Task.sleep(nanoseconds: 30_000_000)
        collector.cancel()
        let events = await collector.value
        // Order: .syncing → .offline (we throw transient).
        XCTAssertTrue(events.contains(.syncing(id)))
        XCTAssertTrue(events.contains(where: {
            if case .offline(let bid) = $0, bid == id { return true } else { return false }
        }))
    }

    func testDisableSyncWhileOfflineKeepsLocalState() async throws {
        let backend = InMemorySyncBackend()
        let store = try await GraphStore.openInMemory()
        let id = SyncBackendID("offline-tests-3")
        let transport = await backend.transport(for: id)
        try await store.enableSync(transport: transport, resolver: FieldLevelMergeResolver())

        _ = try await store.addNode(label: "P", properties: [:])
        await store.disableSync(backendID: id)

        // Local writes still work after disableSync.
        _ = try await store.addNode(label: "P", properties: [:])
        let journal = ChangeJournalStore(store: await store.storeForQueriesUnsafe)
        XCTAssertEqual(try journal.count(), 2)
    }
}
