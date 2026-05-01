import XCTest
@testable import SwiftGraphDB

final class EdgeRepositoryTests: XCTestCase {

    // MARK: - Insert + fetch

    func testInsertThenFetchPreservesAllFields() throws {
        let (store, nodes, edges) = try makeRepos()
        defer { store.close() }
        let from = try insertedPerson(nodes, name: "Alice")
        let to = try insertedPerson(nodes, name: "Bob")

        let edge = Edge(type: "KNOWS", fromID: from, toID: to, properties: ["since": 2021])
        try edges.insert(edge)

        let fetched = try edges.fetch(id: edge.id)
        XCTAssertEqual(fetched?.id, edge.id)
        XCTAssertEqual(fetched?.type, "KNOWS")
        XCTAssertEqual(fetched?.fromID, from)
        XCTAssertEqual(fetched?.toID, to)
        XCTAssertEqual(fetched?.properties, edge.properties)
    }

    func testInsertWithMissingEndpointThrowsTypedError() throws {
        let (store, _, edges) = try makeRepos()
        defer { store.close() }
        let from = IDFactory.live.nodeID()
        let to = IDFactory.live.nodeID()
        XCTAssertThrowsError(try edges.insert(Edge(type: "KNOWS", fromID: from, toID: to))) { error in
            guard case RepositoryError.endpointMissing = error else {
                return XCTFail("expected .endpointMissing, got \(error)")
            }
        }
    }

    // MARK: - Outgoing / incoming queries

    func testFetchOutgoingFiltersByFromAndType() throws {
        let (store, nodes, edges) = try makeRepos()
        defer { store.close() }
        let alice = try insertedPerson(nodes, name: "Alice")
        let bob = try insertedPerson(nodes, name: "Bob")
        let carol = try insertedPerson(nodes, name: "Carol")

        try edges.insert(Edge(type: "KNOWS", fromID: alice, toID: bob))
        try edges.insert(Edge(type: "REFERENCES", fromID: alice, toID: carol))
        try edges.insert(Edge(type: "KNOWS", fromID: bob, toID: carol))

        let outAll = try edges.fetchOutgoing(from: alice, type: nil)
        XCTAssertEqual(outAll.count, 2)

        let outKnows = try edges.fetchOutgoing(from: alice, type: "KNOWS")
        XCTAssertEqual(outKnows.count, 1)
        XCTAssertEqual(outKnows.first?.toID, bob)
    }

    func testFetchIncomingMirrorsOutgoing() throws {
        let (store, nodes, edges) = try makeRepos()
        defer { store.close() }
        let alice = try insertedPerson(nodes, name: "Alice")
        let bob = try insertedPerson(nodes, name: "Bob")

        try edges.insert(Edge(type: "KNOWS", fromID: alice, toID: bob))
        try edges.insert(Edge(type: "KNOWS", fromID: bob, toID: alice))

        let incoming = try edges.fetchIncoming(to: alice, type: "KNOWS")
        XCTAssertEqual(incoming.count, 1)
        XCTAssertEqual(incoming.first?.fromID, bob)
    }

    func testSelfLoopReturnedByBothDirections() throws {
        let (store, nodes, edges) = try makeRepos()
        defer { store.close() }
        let id = try insertedPerson(nodes, name: "Solo")
        try edges.insert(Edge(type: "MENTIONS", fromID: id, toID: id))

        XCTAssertEqual(try edges.fetchOutgoing(from: id, type: nil).count, 1)
        XCTAssertEqual(try edges.fetchIncoming(to: id, type: nil).count, 1)
    }

    func testFetchAllByType() throws {
        let (store, nodes, edges) = try makeRepos()
        defer { store.close() }
        let a = try insertedPerson(nodes, name: "A")
        let b = try insertedPerson(nodes, name: "B")
        let c = try insertedPerson(nodes, name: "C")

        try edges.insert(Edge(type: "KNOWS", fromID: a, toID: b))
        try edges.insert(Edge(type: "KNOWS", fromID: b, toID: c))
        try edges.insert(Edge(type: "REFERENCES", fromID: a, toID: c))

        XCTAssertEqual(try edges.fetchAll(type: "KNOWS").count, 2)
        XCTAssertEqual(try edges.fetchAll(type: "REFERENCES").count, 1)
    }

    // MARK: - Soft delete

    func testSoftDeleteHidesEdgeFromBothDirections() throws {
        let (store, nodes, edges) = try makeRepos()
        defer { store.close() }
        let a = try insertedPerson(nodes, name: "A")
        let b = try insertedPerson(nodes, name: "B")
        let edge = Edge(type: "KNOWS", fromID: a, toID: b)
        try edges.insert(edge)

        try edges.delete(id: edge.id)

        XCTAssertEqual(try edges.fetchOutgoing(from: a, type: nil).count, 0)
        XCTAssertEqual(try edges.fetchIncoming(to: b, type: nil).count, 0)
        XCTAssertNil(try edges.fetch(id: edge.id))
    }

    // MARK: - Index usage

    func testOutgoingQueryUsesFromIndex() throws {
        let (store, _, _) = try makeRepos()
        defer { store.close() }
        let plan = try store.query(
            "EXPLAIN QUERY PLAN SELECT * FROM edges WHERE from_id = ? AND is_deleted = 0",
            [.text(UUID().uuidString)]
        ) { $0.text(at: 3) ?? "" }
        XCTAssertTrue(plan.contains(where: { $0.contains("idx_edges_from") }),
                      "expected idx_edges_from in plan, got \(plan)")
    }

    // MARK: - Helpers

    private func makeRepos() throws -> (SQLiteStore, NodeRepository, EdgeRepository) {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        return (store, NodeRepository(store: store), EdgeRepository(store: store))
    }

    private func insertedPerson(_ repo: NodeRepository, name: String) throws -> NodeID {
        let n = Node(label: "Person", properties: ["name": .string(name)])
        try repo.insert(n)
        return n.id
    }
}
