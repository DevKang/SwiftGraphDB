import XCTest
@testable import SwiftGraphDB

final class NodeTests: XCTestCase {

    // MARK: - Codable round trip

    func testCodableRoundTripPreservesAllFields() throws {
        let id = IDFactory.live.nodeID()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let modified = Date(timeIntervalSince1970: 1_700_000_500)
        let node = Node(
            id: id,
            label: "Person",
            properties: ["name": "Alice", "age": 32, "active": true],
            createdAt: created,
            modifiedAt: modified
        )

        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(Node.self, from: data)

        XCTAssertEqual(decoded.id, node.id)
        XCTAssertEqual(decoded.label, node.label)
        XCTAssertEqual(decoded.properties, node.properties)
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, node.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.modifiedAt.timeIntervalSince1970, node.modifiedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Identity equality

    func testNodesWithSameIDButDifferentLabelsAreEqual() {
        // Identity equality: documented contract — two nodes with the same id are the same entity,
        // even if their labels or properties have diverged in memory.
        let id = IDFactory.live.nodeID()
        let a = Node(id: id, label: "Person")
        let b = Node(id: id, label: "Concept", properties: ["name": "B"])
        XCTAssertEqual(a, b)
    }

    func testNodesWithDifferentIDsAreNotEqual() {
        let a = Node(label: "Person")
        let b = Node(label: "Person")
        XCTAssertNotEqual(a, b) // distinct factory IDs
    }

    func testSetDeduplicatesByID() {
        let id = IDFactory.live.nodeID()
        let a = Node(id: id, label: "Person")
        let b = Node(id: id, label: "Concept")
        let s: Set<Node> = [a, b]
        XCTAssertEqual(s.count, 1)
    }

    // MARK: - with(properties:)

    func testWithPropertiesMergesAndOverrides() {
        let original = Node(label: "Person", properties: ["name": "Alice", "age": 32])
        let updated = original.with(properties: ["age": 33, "email": "a@example.com"])
        XCTAssertEqual(updated.properties["name"], "Alice")     // preserved
        XCTAssertEqual(updated.properties["age"], 33)           // overridden
        XCTAssertEqual(updated.properties["email"], "a@example.com") // added
        XCTAssertEqual(updated.id, original.id)                 // identity preserved
    }

    func testWithPropertiesUpdatesModifiedAt() {
        let original = Node(
            label: "Person",
            properties: ["x": 1],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        Thread.sleep(forTimeInterval: 0.01)
        let updated = original.with(properties: ["x": 2])
        XCTAssertGreaterThan(updated.modifiedAt, original.modifiedAt)
        XCTAssertEqual(updated.createdAt, original.createdAt)
    }
}
