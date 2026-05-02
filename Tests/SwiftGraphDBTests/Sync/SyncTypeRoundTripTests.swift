import XCTest
@testable import SwiftGraphDB

final class SyncTypeRoundTripTests: XCTestCase {

    private func sampleChange(operation: GraphOperation = .upsert) -> GraphChange {
        let payload: GraphRecordPayload? = operation == .upsert
            ? GraphRecordPayload(properties: ["name": "Alice"], label: "Person")
            : nil
        return GraphChange(
            id: UUID(),
            graphID: UUID(),
            actorID: UUID(),
            sequence: 7,
            entity: GraphEntityRef(kind: .node, id: UUID()),
            operation: operation,
            payload: payload,
            baseRevision: GraphRevision(actorID: UUID(), counter: 1, wallClock: Date()),
            revision: GraphRevision(actorID: UUID(), counter: 2, wallClock: Date()),
            createdAt: Date()
        )
    }

    func testGraphChangeRoundTripsThroughJSON() throws {
        let original = sampleChange()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GraphChange.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testValidateRejectsUpsertWithoutPayload() {
        let change = GraphChange(
            id: UUID(), graphID: UUID(), actorID: UUID(),
            sequence: 1, entity: GraphEntityRef(kind: .node, id: UUID()),
            operation: .upsert, payload: nil,
            baseRevision: nil,
            revision: GraphRevision(actorID: UUID(), counter: 1, wallClock: Date()),
            createdAt: Date()
        )
        XCTAssertThrowsError(try change.validate()) { error in
            guard case GraphChangeError.upsertMissingPayload = error else {
                return XCTFail("expected .upsertMissingPayload, got \(error)")
            }
        }
    }

    func testDeleteWithNilPayloadIsValid() throws {
        let change = sampleChange(operation: .delete)
        try change.validate()
    }

    func testGraphChangeIsHashable() {
        let c = sampleChange()
        let s: Set<GraphChange> = [c, c]
        XCTAssertEqual(s.count, 1)
    }

    func testChangeBatchAndCheckpointEncodable() throws {
        let batch = ChangeBatch(
            graphID: UUID(),
            backendID: "test",
            changes: [sampleChange()],
            highWatermark: 100
        )
        let _ = try JSONEncoder().encode(batch)
        let cp = SyncCheckpoint(backendID: "test", data: Data([0x01, 0x02, 0x03]))
        let cpData = try JSONEncoder().encode(cp)
        let decoded = try JSONDecoder().decode(SyncCheckpoint.self, from: cpData)
        XCTAssertEqual(decoded, cp)
    }

    func testProtocolVersionsAreOrderedAndEncodable() throws {
        let v1_0 = SyncProtocolVersion(major: 1, minor: 0)
        let v1_1 = SyncProtocolVersion(major: 1, minor: 1)
        let v2_0 = SyncProtocolVersion(major: 2, minor: 0)
        XCTAssertLessThan(v1_0, v1_1)
        XCTAssertLessThan(v1_1, v2_0)
        let _ = try JSONEncoder().encode(v1_0)
    }

    func testGraphChangeFromJournalRowPreservesIdentity() async throws {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        let actor = await GraphActor(store: store)
        let id = try await actor.addNode(label: "P", properties: ["x": .int(1)])

        let row = try ChangeJournalStore(store: store).latestRow(forEntity: .node, id: id)!
        let change = GraphChange(from: row)
        XCTAssertEqual(change.id, row.changeID)
        XCTAssertEqual(change.entity.id, id)
        XCTAssertEqual(change.operation, .upsert)
        XCTAssertNotNil(change.payload)
    }
}
