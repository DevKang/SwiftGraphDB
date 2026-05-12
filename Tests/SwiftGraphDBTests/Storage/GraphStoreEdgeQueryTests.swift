import XCTest
@testable import SwiftGraphDB

final class GraphStoreEdgeQueryTests: XCTestCase {

    private func makeStore() async throws -> GraphStore {
        try await GraphStore.openInMemory()
    }

    func testEdgeByID() async throws {
        let store = try await makeStore()
        let a = try await store.addNode(label: "N", properties: ["name": .string("A")])
        let b = try await store.addNode(label: "N", properties: ["name": .string("B")])
        let edgeID = try await store.addEdge(from: a, to: b, type: "KNOWS", properties: ["since": .int(2024)])

        let edge = try await store.edge(id: edgeID)
        XCTAssertNotNil(edge)
        XCTAssertEqual(edge?.type, "KNOWS")
        XCTAssertEqual(edge?.fromID, a)
        XCTAssertEqual(edge?.toID, b)
        if case .int(let v) = edge?.properties["since"] {
            XCTAssertEqual(v, 2024)
        } else {
            XCTFail("expected .int property")
        }
    }

    func testEdgeByIDReturnsNilForDeleted() async throws {
        let store = try await makeStore()
        let a = try await store.addNode(label: "N")
        let b = try await store.addNode(label: "N")
        let edgeID = try await store.addEdge(from: a, to: b, type: "T")
        try await store.deleteEdge(id: edgeID)
        let edge = try await store.edge(id: edgeID)
        XCTAssertNil(edge)
    }

    func testEdgesFromNode() async throws {
        let store = try await makeStore()
        let a = try await store.addNode(label: "N")
        let b = try await store.addNode(label: "N")
        let c = try await store.addNode(label: "N")
        _ = try await store.addEdge(from: a, to: b, type: "KNOWS")
        _ = try await store.addEdge(from: a, to: c, type: "WORKS_WITH")
        _ = try await store.addEdge(from: b, to: c, type: "KNOWS")

        let allFromA = try await store.edges(from: a)
        XCTAssertEqual(allFromA.count, 2)

        let knowsFromA = try await store.edges(from: a, type: "KNOWS")
        XCTAssertEqual(knowsFromA.count, 1)
        XCTAssertEqual(knowsFromA[0].toID, b)

        let worksFromA = try await store.edges(from: a, type: "WORKS_WITH")
        XCTAssertEqual(worksFromA.count, 1)
        XCTAssertEqual(worksFromA[0].toID, c)
    }

    func testEdgesToNode() async throws {
        let store = try await makeStore()
        let a = try await store.addNode(label: "N")
        let b = try await store.addNode(label: "N")
        let c = try await store.addNode(label: "N")
        _ = try await store.addEdge(from: a, to: c, type: "KNOWS")
        _ = try await store.addEdge(from: b, to: c, type: "FOLLOWS")

        let allToC = try await store.edges(to: c)
        XCTAssertEqual(allToC.count, 2)

        let followsToC = try await store.edges(to: c, type: "FOLLOWS")
        XCTAssertEqual(followsToC.count, 1)
        XCTAssertEqual(followsToC[0].fromID, b)
    }

    // MARK: - Update Edge

    func testUpdateEdgeMergesProperties() async throws {
        let store = try await makeStore()
        let a = try await store.addNode(label: "N")
        let b = try await store.addNode(label: "N")
        let edgeID = try await store.addEdge(from: a, to: b, type: "KNOWS", properties: ["since": .int(2020), "weight": .double(1.0)])

        try await store.updateEdge(id: edgeID, properties: ["weight": .double(2.5), "note": .string("updated")])

        let edge = try await store.edge(id: edgeID)
        XCTAssertNotNil(edge)
        XCTAssertEqual(edge?.properties["since"], .int(2020))      // preserved
        XCTAssertEqual(edge?.properties["weight"], .double(2.5))   // updated
        XCTAssertEqual(edge?.properties["note"], .string("updated")) // added
    }

    func testUpdateEdgeNullRemovesKey() async throws {
        let store = try await makeStore()
        let a = try await store.addNode(label: "N")
        let b = try await store.addNode(label: "N")
        let edgeID = try await store.addEdge(from: a, to: b, type: "T", properties: ["x": .int(1), "y": .int(2)])

        try await store.updateEdge(id: edgeID, properties: ["y": .null])

        let edge = try await store.edge(id: edgeID)
        XCTAssertEqual(edge?.properties["x"], .int(1))
        XCTAssertNil(edge?.properties["y"], ".null should remove the key")
    }

    func testUpdateNodeNullRemovesKey() async throws {
        let store = try await makeStore()
        let id = try await store.addNode(label: "N", properties: ["a": .string("keep"), "b": .string("remove")])

        try await store.updateNode(id: id, properties: ["b": .null])

        let node = try await store.node(id: id).first()
        XCTAssertEqual(node?.properties["a"], .string("keep"))
        XCTAssertNil(node?.properties["b"], ".null should remove the key")
    }

    func testUpdateEdgeNonExistentThrows() async throws {
        let store = try await makeStore()
        let fakeID = UUID()
        do {
            try await store.updateEdge(id: fakeID, properties: ["x": .int(1)])
            XCTFail("Expected error for non-existent edge")
        } catch {
            // expected
        }
    }

    func testEdgesOfType() async throws {
        let store = try await makeStore()
        let a = try await store.addNode(label: "N")
        let b = try await store.addNode(label: "N")
        let c = try await store.addNode(label: "N")
        _ = try await store.addEdge(from: a, to: b, type: "KNOWS")
        _ = try await store.addEdge(from: b, to: c, type: "KNOWS")
        _ = try await store.addEdge(from: a, to: c, type: "FOLLOWS")

        let allKnows = try await store.edges(ofType: "KNOWS")
        XCTAssertEqual(allKnows.count, 2)

        let allFollows = try await store.edges(ofType: "FOLLOWS")
        XCTAssertEqual(allFollows.count, 1)
    }

    // MARK: - Bulk Insert via GraphStore

    func testBulkInsertViaGraphStore() async throws {
        let store = try await makeStore()
        let summary = try await store.bulkInsert { batch in
            let a = batch.addNode(label: "Person", properties: ["name": .string("Alice")])
            let b = batch.addNode(label: "Person", properties: ["name": .string("Bob")])
            let c = batch.addNode(label: "Person", properties: ["name": .string("Cath")])
            batch.addEdge(from: a, to: b, type: "KNOWS")
            batch.addEdge(from: b, to: c, type: "KNOWS")
        }

        XCTAssertEqual(summary.nodesInserted, 3)
        XCTAssertEqual(summary.edgesInserted, 2)

        // Verify nodes are queryable through the normal query API (in-memory rebuilt)
        let people = try await store.nodes(labeled: "Person").collect()
        XCTAssertEqual(people.count, 3)

        // Verify traversal works (in-memory adjacency was rebuilt)
        let alice = people.first { $0.properties["name"] == .string("Alice") }!
        let network = try await store.node(id: alice.id)
            .traverse(.outgoing, edge: "KNOWS", maxDepth: .bounded(2))
            .collect()
        XCTAssertEqual(network.count, 2) // Bob and Cath
    }
}
