import XCTest
@testable import SwiftGraphDB

final class TransactionTests: XCTestCase {

    private func openStore() async throws -> GraphStore {
        try await GraphStore.openInMemory()
    }

    // MARK: - Happy path

    func testTransactionCommitsAtomically() async throws {
        let store = try await openStore()

        try await store.transaction { tx in
            let a = try tx.addNode(label: "Person", properties: ["name": .string("Alice")])
            let b = try tx.addNode(label: "Person", properties: ["name": .string("Bob")])
            _ = try tx.addEdge(from: a, to: b, type: "KNOWS")
        }

        // Both nodes and the edge should be visible after commit.
        let nodes = try await store.nodes(labeled: "Person").collect()
        XCTAssertEqual(nodes.count, 2)

        let edges = try await store.edgeQuery(type: "KNOWS").collect()
        XCTAssertEqual(edges.count, 1)
    }

    func testTransactionUpdateNode() async throws {
        let store = try await openStore()
        let nodeID = try await store.addNode(label: "Person", properties: ["name": .string("Alice")])

        try await store.transaction { tx in
            try tx.updateNode(id: nodeID, properties: ["name": .string("Bob")])
        }

        let node = try await store.nodes(labeled: "Person").first()
        XCTAssertEqual(node?.properties["name"], .string("Bob"))
    }

    func testTransactionDeleteNode() async throws {
        let store = try await openStore()
        let nodeID = try await store.addNode(label: "Person")

        try await store.transaction { tx in
            try tx.deleteNode(id: nodeID)
        }

        let count = try await store.nodes(labeled: "Person").count()
        XCTAssertEqual(count, 0)
    }

    func testTransactionUpdateEdge() async throws {
        let store = try await openStore()
        let a = try await store.addNode(label: "Person")
        let b = try await store.addNode(label: "Person")
        let edgeID = try await store.addEdge(from: a, to: b, type: "KNOWS", properties: ["weight": .double(1.0)])

        try await store.transaction { tx in
            try tx.updateEdge(id: edgeID, properties: ["weight": .double(2.5)])
        }

        let edge = try await store.edge(id: edgeID)
        XCTAssertEqual(edge?.properties["weight"], .double(2.5))
    }

    func testTransactionDeleteEdge() async throws {
        let store = try await openStore()
        let a = try await store.addNode(label: "Person")
        let b = try await store.addNode(label: "Person")
        let edgeID = try await store.addEdge(from: a, to: b, type: "KNOWS")

        try await store.transaction { tx in
            try tx.deleteEdge(id: edgeID)
        }

        let count = try await store.edgeQuery(type: "KNOWS").count()
        XCTAssertEqual(count, 0)
    }

    // MARK: - Rollback on failure

    func testTransactionRollsBackOnError() async throws {
        let store = try await openStore()
        let existingNode = try await store.addNode(label: "Existing")

        do {
            try await store.transaction { tx in
                _ = try tx.addNode(label: "Temporary", properties: ["x": .int(1)])
                _ = try tx.addNode(label: "Temporary", properties: ["x": .int(2)])
                throw TestTransactionError.intentional
            }
            XCTFail("Expected error to propagate")
        } catch is TestTransactionError {
            // Expected
        }

        // The two Temporary nodes should NOT be visible.
        let tempCount = try await store.nodes(labeled: "Temporary").count()
        XCTAssertEqual(tempCount, 0, "Rolled-back nodes should not be visible")

        // The pre-existing node should still be there.
        let existingCount = try await store.nodes(labeled: "Existing").count()
        XCTAssertEqual(existingCount, 1)
    }

    func testRollbackDoesNotAffectInMemoryState() async throws {
        let store = try await openStore()
        let nodeID = try await store.addNode(label: "Person", properties: ["name": .string("Alice")])

        do {
            try await store.transaction { tx in
                try tx.updateNode(id: nodeID, properties: ["name": .string("SHOULD_NOT_PERSIST")])
                throw TestTransactionError.intentional
            }
        } catch is TestTransactionError {}

        // The node's properties should be unchanged.
        let node = try await store.nodes(labeled: "Person").first()
        XCTAssertEqual(node?.properties["name"], .string("Alice"))
    }

    // MARK: - Mixed operations

    func testMixedOperationsInTransaction() async throws {
        let store = try await openStore()
        let alice = try await store.addNode(label: "Person", properties: ["name": .string("Alice")])

        try await store.transaction { tx in
            let bob = try tx.addNode(label: "Person", properties: ["name": .string("Bob")])
            _ = try tx.addEdge(from: alice, to: bob, type: "KNOWS")
            try tx.updateNode(id: alice, properties: ["age": .int(30)])
        }

        let nodes = try await store.nodes(labeled: "Person").collect()
        XCTAssertEqual(nodes.count, 2)

        let edges = try await store.edgeQuery(type: "KNOWS").collect()
        XCTAssertEqual(edges.count, 1)
    }

    // MARK: - Mutation events

    func testTransactionEmitsMutationEventsOnCommit() async throws {
        let store = try await openStore()
        let stream = await store.changes()

        try await store.transaction { tx in
            let a = try tx.addNode(label: "Person")
            let b = try tx.addNode(label: "Person")
            _ = try tx.addEdge(from: a, to: b, type: "KNOWS")
        }

        // Collect 3 mutations (2 nodeAdded + 1 edgeAdded)
        var mutations: [GraphMutation] = []
        let deadline = Date().addingTimeInterval(2.0)
        for await m in stream {
            mutations.append(m)
            if mutations.count >= 3 { break }
            if Date() > deadline { break }
        }

        XCTAssertEqual(mutations.count, 3)
        // First two should be nodeAdded
        if case .nodeAdded(_, let label) = mutations[0] {
            XCTAssertEqual(label, "Person")
        } else { XCTFail("Expected .nodeAdded") }

        if case .edgeAdded(_, let type, _, _) = mutations[2] {
            XCTAssertEqual(type, "KNOWS")
        } else { XCTFail("Expected .edgeAdded") }
    }

    func testRollbackDoesNotEmitMutationEvents() async throws {
        let store = try await openStore()
        let stream = await store.changes()

        do {
            try await store.transaction { tx in
                _ = try tx.addNode(label: "Ghost")
                throw TestTransactionError.intentional
            }
        } catch is TestTransactionError {}

        // Add a real node to verify stream works.
        _ = try await store.addNode(label: "Real")

        var mutations: [GraphMutation] = []
        let deadline = Date().addingTimeInterval(2.0)
        for await m in stream {
            mutations.append(m)
            if mutations.count >= 1 { break }
            if Date() > deadline { break }
        }

        // Should only see the "Real" node, not the "Ghost" from the rolled-back tx.
        XCTAssertEqual(mutations.count, 1)
        if case .nodeAdded(_, let label) = mutations[0] {
            XCTAssertEqual(label, "Real")
        } else { XCTFail("Expected .nodeAdded(Real)") }
    }
}

private enum TestTransactionError: Error {
    case intentional
}
