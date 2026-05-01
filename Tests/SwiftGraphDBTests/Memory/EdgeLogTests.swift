import XCTest
@testable import SwiftGraphDB

final class EdgeLogTests: XCTestCase {

    // MARK: - Append + iterate

    func testInsertedEntryAppearsInOutgoingAndIncoming() {
        var log = EdgeLog()
        let from = IDFactory.live.nodeID()
        let to = IDFactory.live.nodeID()
        let edgeID = IDFactory.live.edgeID()
        log.append(EdgeLogEntry(
            edgeID: edgeID, fromID: from, toID: to, type: "KNOWS",
            timestamp: Date(), operation: .insert
        ))

        XCTAssertEqual(Array(log.outgoingEntries(from: from)).map(\.edgeID), [edgeID])
        XCTAssertEqual(Array(log.incomingEntries(to: to)).map(\.edgeID), [edgeID])
    }

    func testSizeReflectsAppendedEntryCount() {
        var log = EdgeLog()
        XCTAssertEqual(log.size, 0)
        for _ in 0..<5 {
            log.append(.init(
                edgeID: IDFactory.live.edgeID(),
                fromID: IDFactory.live.nodeID(),
                toID: IDFactory.live.nodeID(),
                type: "L",
                timestamp: Date(), operation: .insert
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
                timestamp: Date().addingTimeInterval(TimeInterval(i)),
                operation: .insert
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
            timestamp: Date(), operation: .delete
        )]
        let merged = EdgeLog.merge(csrEdges: csrSlice, logEntries: entries)
        XCTAssertEqual(merged.map(\.edgeID), [keptEdgeID])
    }

    func testSecondInsertOfSameEdgeIDReplacesFirst() {
        let from = IDFactory.live.nodeID()
        let to1 = IDFactory.live.nodeID()
        let to2 = IDFactory.live.nodeID()
        let edgeID = IDFactory.live.edgeID()

        let entries: [EdgeLogEntry] = [
            .init(edgeID: edgeID, fromID: from, toID: to1, type: "L",
                  timestamp: Date(), operation: .insert),
            .init(edgeID: edgeID, fromID: from, toID: to2, type: "L",
                  timestamp: Date().addingTimeInterval(1), operation: .insert),
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
                  timestamp: Date(), operation: .insert),
            .init(edgeID: edgeID, fromID: from, toID: to, type: "L",
                  timestamp: Date().addingTimeInterval(1), operation: .delete),
            .init(edgeID: edgeID, fromID: from, toID: to, type: "L",
                  timestamp: Date().addingTimeInterval(2), operation: .insert),
        ]

        let merged = EdgeLog.merge(csrEdges: [], logEntries: entries)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.edgeID, edgeID)
    }
}
