import XCTest
@testable import SwiftGraphDB

final class MutationObservationTests: XCTestCase {

    // MARK: - Helpers

    private func openStore() async throws -> GraphStore {
        try await GraphStore.openInMemory()
    }

    /// Collect mutations from a stream up to `expected` count, with a timeout.
    private func collect(
        _ stream: AsyncStream<GraphMutation>,
        expected: Int,
        timeout: TimeInterval = 2.0
    ) async -> [GraphMutation] {
        var results: [GraphMutation] = []
        let deadline = Date().addingTimeInterval(timeout)
        for await mutation in stream {
            results.append(mutation)
            if results.count >= expected { break }
            if Date() > deadline { break }
        }
        return results
    }

    // MARK: - nodeAdded

    func testNodeAddedEmitted() async throws {
        let store = try await openStore()
        let stream = await store.changes()

        let nodeID = try await store.addNode(label: "Person", properties: ["name": .string("Alice")])

        let mutations = await collect(stream, expected: 1)
        XCTAssertEqual(mutations.count, 1)
        if case .nodeAdded(let id, let label) = mutations[0] {
            XCTAssertEqual(id, nodeID)
            XCTAssertEqual(label, "Person")
        } else {
            XCTFail("Expected .nodeAdded, got \(mutations[0])")
        }
    }

    // MARK: - edgeAdded

    func testEdgeAddedEmitted() async throws {
        let store = try await openStore()
        let a = try await store.addNode(label: "Person")
        let b = try await store.addNode(label: "Person")

        let stream = await store.changes()

        let edgeID = try await store.addEdge(from: a, to: b, type: "KNOWS", properties: ["since": .int(2024)])

        let mutations = await collect(stream, expected: 1)
        XCTAssertEqual(mutations.count, 1)
        if case .edgeAdded(let id, let type, let from, let to) = mutations[0] {
            XCTAssertEqual(id, edgeID)
            XCTAssertEqual(type, "KNOWS")
            XCTAssertEqual(from, a)
            XCTAssertEqual(to, b)
        } else {
            XCTFail("Expected .edgeAdded, got \(mutations[0])")
        }
    }

    // MARK: - nodeUpdated

    func testNodeUpdatedEmitted() async throws {
        let store = try await openStore()
        let nodeID = try await store.addNode(label: "Person", properties: ["name": .string("Alice")])

        let stream = await store.changes()

        try await store.updateNode(id: nodeID, properties: ["name": .string("Bob")])

        let mutations = await collect(stream, expected: 1)
        XCTAssertEqual(mutations.count, 1)
        if case .nodeUpdated(let id) = mutations[0] {
            XCTAssertEqual(id, nodeID)
        } else {
            XCTFail("Expected .nodeUpdated, got \(mutations[0])")
        }
    }

    // MARK: - edgeUpdated

    func testEdgeUpdatedEmitted() async throws {
        let store = try await openStore()
        let a = try await store.addNode(label: "Person")
        let b = try await store.addNode(label: "Person")
        let edgeID = try await store.addEdge(from: a, to: b, type: "KNOWS")

        let stream = await store.changes()

        try await store.updateEdge(id: edgeID, properties: ["weight": .double(1.5)])

        let mutations = await collect(stream, expected: 1)
        XCTAssertEqual(mutations.count, 1)
        if case .edgeUpdated(let id) = mutations[0] {
            XCTAssertEqual(id, edgeID)
        } else {
            XCTFail("Expected .edgeUpdated, got \(mutations[0])")
        }
    }

    // MARK: - nodeDeleted

    func testNodeDeletedEmitted() async throws {
        let store = try await openStore()
        let nodeID = try await store.addNode(label: "Person")

        let stream = await store.changes()

        try await store.deleteNode(id: nodeID)

        let mutations = await collect(stream, expected: 1)
        XCTAssertEqual(mutations.count, 1)
        if case .nodeDeleted(let id) = mutations[0] {
            XCTAssertEqual(id, nodeID)
        } else {
            XCTFail("Expected .nodeDeleted, got \(mutations[0])")
        }
    }

    // MARK: - edgeDeleted

    func testEdgeDeletedEmitted() async throws {
        let store = try await openStore()
        let a = try await store.addNode(label: "Person")
        let b = try await store.addNode(label: "Person")
        let edgeID = try await store.addEdge(from: a, to: b, type: "KNOWS")

        let stream = await store.changes()

        try await store.deleteEdge(id: edgeID)

        let mutations = await collect(stream, expected: 1)
        XCTAssertEqual(mutations.count, 1)
        if case .edgeDeleted(let id) = mutations[0] {
            XCTAssertEqual(id, edgeID)
        } else {
            XCTFail("Expected .edgeDeleted, got \(mutations[0])")
        }
    }

    // MARK: - Multiple mutations in sequence

    func testMultipleMutationsInOrder() async throws {
        let store = try await openStore()
        let stream = await store.changes()

        let a = try await store.addNode(label: "Person", properties: ["name": .string("A")])
        let b = try await store.addNode(label: "Person", properties: ["name": .string("B")])
        let e = try await store.addEdge(from: a, to: b, type: "KNOWS")
        try await store.updateNode(id: a, properties: ["name": .string("Updated")])
        try await store.deleteEdge(id: e)
        try await store.deleteNode(id: b)

        let mutations = await collect(stream, expected: 6)
        XCTAssertEqual(mutations.count, 6)

        // Verify order
        if case .nodeAdded(let id, _) = mutations[0] { XCTAssertEqual(id, a) }
        else { XCTFail("Expected .nodeAdded") }

        if case .nodeAdded(let id, _) = mutations[1] { XCTAssertEqual(id, b) }
        else { XCTFail("Expected .nodeAdded") }

        if case .edgeAdded(let id, _, _, _) = mutations[2] { XCTAssertEqual(id, e) }
        else { XCTFail("Expected .edgeAdded") }

        if case .nodeUpdated(let id) = mutations[3] { XCTAssertEqual(id, a) }
        else { XCTFail("Expected .nodeUpdated") }

        if case .edgeDeleted(let id) = mutations[4] { XCTAssertEqual(id, e) }
        else { XCTFail("Expected .edgeDeleted") }

        if case .nodeDeleted(let id) = mutations[5] { XCTAssertEqual(id, b) }
        else { XCTFail("Expected .nodeDeleted") }
    }

    // MARK: - Multiple subscribers

    func testMultipleSubscribersReceiveEvents() async throws {
        let store = try await openStore()
        let stream1 = await store.changes()
        let stream2 = await store.changes()

        let nodeID = try await store.addNode(label: "Person")

        let m1 = await collect(stream1, expected: 1)
        let m2 = await collect(stream2, expected: 1)

        XCTAssertEqual(m1.count, 1)
        XCTAssertEqual(m2.count, 1)
        if case .nodeAdded(let id, _) = m1[0] { XCTAssertEqual(id, nodeID) }
        if case .nodeAdded(let id, _) = m2[0] { XCTAssertEqual(id, nodeID) }
    }
}
