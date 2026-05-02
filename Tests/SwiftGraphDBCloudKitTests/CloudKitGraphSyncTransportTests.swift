import XCTest
@testable import SwiftGraphDB
@testable import SwiftGraphDBCloudKit

final class CloudKitGraphSyncTransportTests: XCTestCase {

    // MARK: - Fixtures

    private func makeChange(
        kind: GraphEntityKind = .node,
        id: UUID = UUID(),
        actor: ActorID = ActorID(),
        operation: GraphOperation = .upsert,
        properties: [String: PropertyValue] = ["name": "Alice"]
    ) -> GraphChange {
        let payload: GraphRecordPayload? = operation == .upsert
            ? GraphRecordPayload(properties: properties, label: kind == .node ? "Person" : nil,
                                 type: kind == .edge ? "KNOWS" : nil,
                                 fromID: kind == .edge ? UUID() : nil,
                                 toID: kind == .edge ? UUID() : nil)
            : nil
        return GraphChange(
            id: UUID(), graphID: UUID(), actorID: actor,
            sequence: 1,
            entity: GraphEntityRef(kind: kind, id: id),
            operation: operation,
            payload: payload,
            baseRevision: nil,
            revision: GraphRevision(actorID: actor, counter: 1, wallClock: Date()),
            createdAt: Date()
        )
    }

    private func makeBatch(_ changes: [GraphChange]) -> ChangeBatch {
        ChangeBatch(graphID: UUID(), backendID: SyncBackendID("test-device"), changes: changes, highWatermark: 0)
    }

    // MARK: - Push

    func testPushTranslatesChangesIntoModifyCall() async throws {
        let mock = MockCloudKitDatabase()
        let transport = CloudKitGraphSyncTransport(backendID: SyncBackendID("dev"), database: mock)

        let c1 = makeChange()
        let c2 = makeChange(kind: .edge)
        let result = try await transport.push(makeBatch([c1, c2]))

        let saved = await mock.lastSaveCallSavedRecords
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(Set(saved.map(\.recordType)),
                       Set([SwiftGraphDBCloudKit.recordTypeNode, SwiftGraphDBCloudKit.recordTypeEdge]))
        XCTAssertEqual(Set(result.accepted), Set([c1.id, c2.id]))
        XCTAssertTrue(result.rejected.isEmpty)
        // CloudKit does not return a new server change token from a push — only fetches do.
        XCTAssertNil(result.checkpoint)
    }

    func testPushTranslatesDeleteIntoDeleteRecordIDs() async throws {
        let mock = MockCloudKitDatabase()
        let transport = CloudKitGraphSyncTransport(backendID: SyncBackendID("dev"), database: mock)

        let delete = makeChange(operation: .delete)
        _ = try await transport.push(makeBatch([delete]))

        let deleted = await mock.lastSaveCallDeletedIDs
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(deleted.first?.entity?.id, delete.entity.id)
    }

    // MARK: - Conflicts

    func testServerConflictMapsToConflictRejection() async throws {
        let mock = MockCloudKitDatabase()
        let local = makeChange(properties: ["name": "Alice"])
        let serverChange = makeChange(id: local.entity.id, properties: ["name": "Server"])
        let serverRecord = try RecordCodec.encode(serverChange)
        let localRecord = try RecordCodec.encode(local)
        await mock.queueConflict((record: localRecord, serverRecord: serverRecord))

        let transport = CloudKitGraphSyncTransport(backendID: SyncBackendID("dev"), database: mock)
        let result = try await transport.push(makeBatch([local]))

        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.rejected.count, 1)
        let rejection = result.rejected[0]
        XCTAssertEqual(rejection.changeID, local.id)
        guard case .conflict(let remote, _) = rejection.reason else {
            return XCTFail("expected conflict rejection, got \(rejection.reason)")
        }
        XCTAssertEqual(remote.properties["name"], "Server")
    }

    // MARK: - Pull

    func testPullTranslatesRecordsIntoChangesAndExposesNewCheckpoint() async throws {
        let mock = MockCloudKitDatabase()
        let remote = makeChange(properties: ["name": "Bob"])
        let record = try RecordCodec.encode(remote)
        let token = Data([0xCA, 0xFE])
        await mock.queueFetch(CloudKitFetchResult(
            changedRecords: [record],
            deletedRecordIDs: [],
            serverChangeToken: token,
            moreComing: false
        ))

        let transport = CloudKitGraphSyncTransport(backendID: SyncBackendID("dev"), database: mock)
        let result = try await transport.pull(since: nil)

        XCTAssertEqual(result.changes.count, 1)
        XCTAssertEqual(result.changes[0].id, remote.id)
        XCTAssertEqual(result.checkpoint.data, token)
        XCTAssertFalse(result.hasMore)
    }

    func testPullDeletedRecordIDProducesDeleteChange() async throws {
        let mock = MockCloudKitDatabase()
        let entityID = UUID()
        let recordID = CloudKitRecordID.make(from: GraphEntityRef(kind: .node, id: entityID))
        await mock.queueFetch(CloudKitFetchResult(
            changedRecords: [],
            deletedRecordIDs: [recordID],
            serverChangeToken: Data([0x01]),
            moreComing: false
        ))

        let transport = CloudKitGraphSyncTransport(backendID: SyncBackendID("dev"), database: mock)
        let result = try await transport.pull(since: nil)

        XCTAssertEqual(result.changes.count, 1)
        XCTAssertEqual(result.changes[0].operation, .delete)
        XCTAssertEqual(result.changes[0].entity.id, entityID)
    }

    func testPullPropagatesHasMore() async throws {
        let mock = MockCloudKitDatabase()
        await mock.queueFetch(CloudKitFetchResult(
            changedRecords: [],
            deletedRecordIDs: [],
            serverChangeToken: Data([0x02]),
            moreComing: true
        ))
        let transport = CloudKitGraphSyncTransport(backendID: SyncBackendID("dev"), database: mock)
        let result = try await transport.pull(since: nil)
        XCTAssertTrue(result.hasMore)
    }

    // MARK: - Transient errors

    func testTransientErrorOnPushBecomesRetryableRejection() async throws {
        let mock = MockCloudKitDatabase()
        await mock.setNextSaveError(.networkFailure)

        let transport = CloudKitGraphSyncTransport(backendID: SyncBackendID("dev"), database: mock)
        let change = makeChange()
        let result = try await transport.push(makeBatch([change]))
        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.rejected.count, 1)
        guard case .transient = result.rejected[0].reason else {
            return XCTFail("expected transient, got \(result.rejected[0].reason)")
        }
    }

    func testTransientErrorOnPullThrows() async {
        let mock = MockCloudKitDatabase()
        await mock.setNextFetchError(.networkFailure)

        let transport = CloudKitGraphSyncTransport(backendID: SyncBackendID("dev"), database: mock)
        do {
            _ = try await transport.pull(since: nil)
            XCTFail("expected throw")
        } catch {
            // ok — pull surfaces the error so the SyncRegistry status loop can transition to .offline.
        }
    }

    // MARK: - Sendable / actor hop survival

    func testTransportSurvivesDetachedTaskHop() async throws {
        let mock = MockCloudKitDatabase()
        let transport = CloudKitGraphSyncTransport(backendID: SyncBackendID("dev"), database: mock)
        let change = makeChange()
        let batch = makeBatch([change])
        let result = try await Task.detached { [transport, batch] in
            try await transport.push(batch)
        }.value
        XCTAssertEqual(result.accepted, [change.id])
    }
}
