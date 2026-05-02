import XCTest
@testable import SwiftGraphDB

final class EdgeLogTests: XCTestCase {

    private let testActor = ActorID()

    private func revision(_ counter: Int64, offset: TimeInterval = 0) -> GraphRevision {
        GraphRevision(actorID: testActor, counter: counter, wallClock: Date().addingTimeInterval(offset))
    }

    // MARK: - Append + iterate

    func testInsertedEntryAppearsInOutgoingAndIncoming() {
        var log = EdgeLog()
        let from = IDFactory.live.nodeID()
        let to = IDFactory.live.nodeID()
        let edgeID = IDFactory.live.edgeID()
        log.append(EdgeLogEntry(
            edgeID: edgeID, fromID: from, toID: to, type: "KNOWS",
            revision: revision(1), operation: .upsert
        ))

        XCTAssertEqual(Array(log.outgoingEntries(from: from)).map(\.edgeID), [edgeID])
        XCTAssertEqual(Array(log.incomingEntries(to: to)).map(\.edgeID), [edgeID])
    }

    func testSizeReflectsAppendedEntryCount() {
        var log = EdgeLog()
        XCTAssertEqual(log.size, 0)
        for i in 0..<5 {
            log.append(.init(
                edgeID: IDFactory.live.edgeID(),
                fromID: IDFactory.live.nodeID(),
                toID: IDFactory.live.nodeID(),
                type: "L",
                revision: revision(Int64(i + 1)), operation: .upsert
            ))
        }
        XCTAssertEqual(log.size, 5)
    }

    // MARK: - merge() rules

    func testMergeWithEmptyLogReturnsCSREdgesUnchanged() {
        let csrSlice: ArraySlice<EdgeRecord> = ArraySlice([
            .init(toID: IDFactory.live.nodeID(), edgeID: IDFactory.live.edgeID(), type: "L"),
            .init(toID: IDFactory.live.nodeID(), edgeID: IDFactory.live.edgeID(), type: "L"),
        ])
        let merged = EdgeLog.merge(csrEdges: csrSlice, logEntries: [])
        XCTAssertEqual(merged, Array(csrSlice))
    }

    func testMergeWithEmptyCSRReturnsLogInsertsInOrder() {
        let from = IDFactory.live.nodeID()
        let entries: [EdgeLogEntry] = (0..<3).map { i in
            .init(
                edgeID: IDFactory.live.edgeID(), fromID: from,
                toID: IDFactory.live.nodeID(),
                type: "L",
                revision: revision(Int64(i + 1)),
                operation: .upsert
            )
        }
        let merged = EdgeLog.merge(csrEdges: [], logEntries: entries)
        XCTAssertEqual(merged.map(\.edgeID), entries.map(\.edgeID))
    }

    func testDeleteEntrySuppressesMatchingCSREdge() {
        let from = IDFactory.live.nodeID()
        let to = IDFactory.live.nodeID()
        let toKeep = IDFactory.live.nodeID()
        let killedEdgeID = IDFactory.live.edgeID()
        let keptEdgeID = IDFactory.live.edgeID()

        let csrSlice: ArraySlice<EdgeRecord> = ArraySlice([
            .init(toID: to, edgeID: killedEdgeID, type: "L"),
            .init(toID: toKeep, edgeID: keptEdgeID, type: "L"),
        ])
        let entries = [EdgeLogEntry(
            edgeID: killedEdgeID, fromID: from, toID: to, type: "L",
            revision: revision(1), operation: .delete
        )]
        let merged = EdgeLog.merge(csrEdges: csrSlice, logEntries: entries)
        XCTAssertEqual(merged.map(\.edgeID), [keptEdgeID])
    }

    func testSecondInsertOfSameEdgeIDReplacesFirstByCounter() {
        let from = IDFactory.live.nodeID()
        let to1 = IDFactory.live.nodeID()
        let to2 = IDFactory.live.nodeID()
        let edgeID = IDFactory.live.edgeID()

        let entries: [EdgeLogEntry] = [
            .init(edgeID: edgeID, fromID: from, toID: to1, type: "L",
                  revision: revision(1), operation: .upsert),
            .init(edgeID: edgeID, fromID: from, toID: to2, type: "L",
                  revision: revision(2), operation: .upsert),
        ]

        let merged = EdgeLog.merge(csrEdges: [], logEntries: entries)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.toID, to2)
    }

    func testInsertThenDeleteThenInsertEndsAsLive() {
        let from = IDFactory.live.nodeID()
        let to = IDFactory.live.nodeID()
        let edgeID = IDFactory.live.edgeID()

        let entries: [EdgeLogEntry] = [
            .init(edgeID: edgeID, fromID: from, toID: to, type: "L",
                  revision: revision(1), operation: .upsert),
            .init(edgeID: edgeID, fromID: from, toID: to, type: "L",
                  revision: revision(2, offset: 1), operation: .delete),
            .init(edgeID: edgeID, fromID: from, toID: to, type: "L",
                  revision: revision(3, offset: 2), operation: .upsert),
        ]

        let merged = EdgeLog.merge(csrEdges: [], logEntries: entries)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.edgeID, edgeID)
    }

    // MARK: - Cross-actor revision tiebreak

    func testCrossActorMergePicksHighestRevisionByWallClock() {
        let from = IDFactory.live.nodeID()
        let to = IDFactory.live.nodeID()
        let edgeID = IDFactory.live.edgeID()

        let actorA = ActorID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let actorB = ActorID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)

        let entries: [EdgeLogEntry] = [
            .init(edgeID: edgeID, fromID: from, toID: to, type: "L",
                  revision: GraphRevision(actorID: actorA, counter: 99, wallClock: early),
                  operation: .upsert),
            .init(edgeID: edgeID, fromID: from, toID: to, type: "L",
                  revision: GraphRevision(actorID: actorB, counter: 1, wallClock: late),
                  operation: .delete),
        ]
        let merged = EdgeLog.merge(csrEdges: [], logEntries: entries)
        XCTAssertEqual(merged.count, 0, "later wallClock delete wins regardless of counter")
    }
}
