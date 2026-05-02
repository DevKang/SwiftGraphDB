import XCTest
@testable import SwiftGraphDB
@testable import SwiftGraphDBCloudKit

final class RecordCodecTests: XCTestCase {

    private func nodeChange() -> GraphChange {
        GraphChange(
            id: UUID(), graphID: UUID(), actorID: UUID(),
            sequence: 1,
            entity: GraphEntityRef(kind: .node, id: UUID()),
            operation: .upsert,
            payload: GraphRecordPayload(properties: ["name": "Alice"], label: "Person"),
            baseRevision: nil,
            revision: GraphRevision(actorID: UUID(), counter: 1, wallClock: Date()),
            createdAt: Date()
        )
    }

    private func edgeChange() -> GraphChange {
        let from = UUID(); let to = UUID()
        return GraphChange(
            id: UUID(), graphID: UUID(), actorID: UUID(),
            sequence: 1,
            entity: GraphEntityRef(kind: .edge, id: UUID()),
            operation: .upsert,
            payload: GraphRecordPayload(properties: [:], type: "KNOWS", fromID: from, toID: to),
            baseRevision: nil,
            revision: GraphRevision(actorID: UUID(), counter: 1, wallClock: Date()),
            createdAt: Date()
        )
    }

    func testNodeChangeRoundTrip() throws {
        let original = nodeChange()
        let record = try RecordCodec.encode(original)
        XCTAssertEqual(record.recordType, SwiftGraphDBCloudKit.recordTypeNode)
        XCTAssertEqual(record.id.entity?.id, original.entity.id)
        let decoded = try RecordCodec.decode(record)
        XCTAssertEqual(decoded, original)
    }

    func testEdgeChangeRoundTrip() throws {
        let original = edgeChange()
        let record = try RecordCodec.encode(original)
        XCTAssertEqual(record.recordType, SwiftGraphDBCloudKit.recordTypeEdge)
        let decoded = try RecordCodec.decode(record)
        XCTAssertEqual(decoded, original)
    }

    func testRecordIDIsDeterministicAcrossEncodes() throws {
        let change = nodeChange()
        let r1 = try RecordCodec.encode(change)
        let r2 = try RecordCodec.encode(change)
        XCTAssertEqual(r1.id, r2.id)
    }

    func testTombstoneRoundTrip() throws {
        var change = nodeChange()
        change = GraphChange(
            id: change.id, graphID: change.graphID, actorID: change.actorID,
            sequence: change.sequence, entity: change.entity, operation: .delete,
            payload: nil, baseRevision: change.revision,
            revision: change.revision, createdAt: change.createdAt
        )
        let record = try RecordCodec.encode(change)
        let decoded = try RecordCodec.decode(record)
        XCTAssertEqual(decoded.operation, .delete)
        XCTAssertNil(decoded.payload)
    }

    func testMissingChangeFieldThrows() {
        let bad = CloudKitRecord(id: CloudKitRecordID(recordName: "node:\(UUID())"), recordType: "GDB_Node", fields: [:])
        XCTAssertThrowsError(try RecordCodec.decode(bad)) { err in
            guard case RecordCodecError.missingChangeField = err else {
                return XCTFail("expected .missingChangeField, got \(err)")
            }
        }
    }

    func testFutureMajorPayloadFormatRejected() throws {
        var change = nodeChange()
        let futurePayload = GraphRecordPayload(
            format: PayloadFormatVersion(major: PayloadFormatVersion.current.major + 1, minor: 0),
            properties: ["x": .int(1)], label: "P"
        )
        change = GraphChange(
            id: change.id, graphID: change.graphID, actorID: change.actorID,
            sequence: change.sequence, entity: change.entity, operation: .upsert,
            payload: futurePayload, baseRevision: change.baseRevision,
            revision: change.revision, createdAt: change.createdAt
        )
        let record = try RecordCodec.encode(change)
        XCTAssertThrowsError(try RecordCodec.decode(record)) { err in
            guard case RecordCodecError.unsupportedPayloadFormat = err else {
                return XCTFail("expected .unsupportedPayloadFormat, got \(err)")
            }
        }
    }

    func testRecordIDExtractsEntity() {
        let id = UUID()
        let recordID = CloudKitRecordID.make(from: GraphEntityRef(kind: .node, id: id))
        let entity = recordID.entity
        XCTAssertEqual(entity?.kind, .node)
        XCTAssertEqual(entity?.id, id)
    }
}
