import XCTest
@testable import SwiftGraphDB

final class EdgeTests: XCTestCase {

    func testCodableRoundTripPreservesAllFields() throws {
        let edgeID = IDFactory.live.edgeID()
        let from = IDFactory.live.nodeID()
        let to = IDFactory.live.nodeID()
        let edge = Edge(
            id: edgeID,
            type: "KNOWS",
            fromID: from,
            toID: to,
            properties: ["since": 2021, "weight": 0.7]
        )

        let data = try JSONEncoder().encode(edge)
        let decoded = try JSONDecoder().decode(Edge.self, from: data)

        XCTAssertEqual(decoded.id, edge.id)
        XCTAssertEqual(decoded.type, edge.type)
        XCTAssertEqual(decoded.fromID, edge.fromID)
        XCTAssertEqual(decoded.toID, edge.toID)
        XCTAssertEqual(decoded.properties, edge.properties)
    }

    func testEdgesWithSameIDAreEqualEvenIfShapeDiffers() {
        let id = IDFactory.live.edgeID()
        let from = IDFactory.live.nodeID()
        let to = IDFactory.live.nodeID()
        let other = IDFactory.live.nodeID()
        let a = Edge(id: id, type: "KNOWS", fromID: from, toID: to)
        let b = Edge(id: id, type: "REFERENCES", fromID: from, toID: other)
        XCTAssertEqual(a, b)
    }

    func testSetDeduplicatesByID() {
        let id = IDFactory.live.edgeID()
        let n1 = IDFactory.live.nodeID()
        let n2 = IDFactory.live.nodeID()
        let a = Edge(id: id, type: "KNOWS", fromID: n1, toID: n2)
        let b = Edge(id: id, type: "REFERENCES", fromID: n1, toID: n2)
        let s: Set<Edge> = [a, b]
        XCTAssertEqual(s.count, 1)
    }

    func testSelfLoopRoundTrips() throws {
        let nodeID = IDFactory.live.nodeID()
        let edge = Edge(type: "MENTIONS", fromID: nodeID, toID: nodeID)
        XCTAssertEqual(edge.fromID, edge.toID)
        let data = try JSONEncoder().encode(edge)
        let decoded = try JSONDecoder().decode(Edge.self, from: data)
        XCTAssertEqual(decoded.fromID, decoded.toID)
        XCTAssertEqual(decoded.fromID, nodeID)
    }

    func testWithPropertiesMergesAndBumpsModifiedAt() {
        let n1 = IDFactory.live.nodeID()
        let n2 = IDFactory.live.nodeID()
        let original = Edge(
            type: "KNOWS",
            fromID: n1,
            toID: n2,
            properties: ["since": 2021],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        Thread.sleep(forTimeInterval: 0.01)
        let updated = original.with(properties: ["since": 2022, "weight": 1.0])
        XCTAssertEqual(updated.properties["since"], 2022)
        XCTAssertEqual(updated.properties["weight"], 1.0)
        XCTAssertGreaterThan(updated.modifiedAt, original.modifiedAt)
        XCTAssertEqual(updated.createdAt, original.createdAt)
        XCTAssertEqual(updated.id, original.id)
    }
}
