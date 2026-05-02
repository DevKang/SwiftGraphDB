import XCTest
@testable import SwiftGraphDB

final class NodeV2Tests: XCTestCase {

    func testNewFieldsRoundTripThroughCodable() throws {
        let actorID = ActorID()
        let revision = GraphRevision(actorID: actorID, counter: 5, wallClock: Date(timeIntervalSince1970: 1700000000))
        let node = Node(
            id: IDFactory.live.nodeID(),
            label: "Person",
            properties: ["name": "Alice"],
            createdAt: Date(timeIntervalSince1970: 1699999000),
            modifiedAt: Date(timeIntervalSince1970: 1700000000),
            revision: revision,
            isDeleted: false
        )
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(Node.self, from: data)
        XCTAssertEqual(decoded.revision, revision)
        XCTAssertEqual(decoded.isDeleted, false)
        XCTAssertEqual(decoded.properties, node.properties)
    }

    func testTombstonedNodeRoundTrips() throws {
        var node = Node(label: "Person")
        node.isDeleted = true
        let decoded = try JSONDecoder().decode(Node.self, from: try JSONEncoder().encode(node))
        XCTAssertTrue(decoded.isDeleted)
    }

    func testDecodingV1ShapedJSONUsesDefaults() throws {
        // V1 JSON: no `revision`, no `isDeleted`. Existing Codable round-trip stays compatible.
        let v1: [String: Any] = [
            "id": UUID().uuidString,
            "label": "Person",
            "properties": ["name": ["type": "string", "value": "Alice"]],
            "createdAt": 1700000000.0,
            "modifiedAt": 1700000000.0
        ]
        let data = try JSONSerialization.data(withJSONObject: v1)
        let decoded = try JSONDecoder().decode(Node.self, from: data)
        XCTAssertEqual(decoded.label, "Person")
        XCTAssertFalse(decoded.isDeleted)
        XCTAssertEqual(decoded.revision.counter, 0, "placeholder revision (counter 0)")
    }

    func testIdentityEqualityIgnoresRevision() {
        let id = IDFactory.live.nodeID()
        let actor = ActorID()
        let n1 = Node(id: id, label: "Person", revision: GraphRevision(actorID: actor, counter: 1, wallClock: Date()))
        let n2 = Node(id: id, label: "Person", revision: GraphRevision(actorID: actor, counter: 99, wallClock: Date()))
        XCTAssertEqual(n1, n2)
        XCTAssertEqual(n1.hashValue, n2.hashValue)
    }

    func testWithPropertiesPreservesRevision() {
        let actor = ActorID()
        let revision = GraphRevision(actorID: actor, counter: 7, wallClock: Date())
        let original = Node(label: "Person", properties: ["x": 1], revision: revision)
        let updated = original.with(properties: ["x": 2])
        XCTAssertEqual(updated.revision, revision, "with(properties:) does not auto-bump revision; the actor stamps it on commit")
    }

    func testDefaultRevisionIsPlaceholder() {
        let node = Node(label: "Person")
        XCTAssertEqual(node.revision.counter, 0)
        XCTAssertFalse(node.isDeleted)
    }
}

final class EdgeV2Tests: XCTestCase {

    func testNewFieldsRoundTripThroughCodable() throws {
        let actor = ActorID()
        let revision = GraphRevision(actorID: actor, counter: 12, wallClock: Date())
        let edge = Edge(
            type: "KNOWS",
            fromID: IDFactory.live.nodeID(),
            toID: IDFactory.live.nodeID(),
            properties: ["since": 2021],
            revision: revision,
            isDeleted: false
        )
        let decoded = try JSONDecoder().decode(Edge.self, from: try JSONEncoder().encode(edge))
        XCTAssertEqual(decoded.revision, revision)
        XCTAssertFalse(decoded.isDeleted)
    }

    func testV1JSONDecodesToDefaults() throws {
        let n1 = UUID().uuidString
        let n2 = UUID().uuidString
        let v1: [String: Any] = [
            "id": UUID().uuidString,
            "type": "KNOWS",
            "fromID": n1,
            "toID": n2,
            "properties": [String: Any](),
            "createdAt": 1700000000.0,
            "modifiedAt": 1700000000.0
        ]
        let decoded = try JSONDecoder().decode(Edge.self, from: try JSONSerialization.data(withJSONObject: v1))
        XCTAssertEqual(decoded.type, "KNOWS")
        XCTAssertFalse(decoded.isDeleted)
    }

    func testIdentityEqualityIgnoresRevisionAndDeletedFlag() {
        let id = IDFactory.live.edgeID()
        let nA = IDFactory.live.nodeID()
        let nB = IDFactory.live.nodeID()
        let actor = ActorID()
        let e1 = Edge(id: id, type: "KNOWS", fromID: nA, toID: nB,
                      revision: GraphRevision(actorID: actor, counter: 1, wallClock: Date()))
        var e2 = Edge(id: id, type: "REFERENCES", fromID: nA, toID: nB,
                      revision: GraphRevision(actorID: actor, counter: 2, wallClock: Date()))
        e2.isDeleted = true
        XCTAssertEqual(e1, e2)
    }
}
