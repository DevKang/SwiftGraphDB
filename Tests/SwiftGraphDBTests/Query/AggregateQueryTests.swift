import XCTest
@testable import SwiftGraphDB

final class AggregateQueryTests: XCTestCase {

    private func seedStore() async throws -> GraphStore {
        let store = try await GraphStore.openInMemory()
        _ = try await store.addNode(label: "Person", properties: ["name": .string("Alice"), "age": .int(30), "score": .double(4.5)])
        _ = try await store.addNode(label: "Person", properties: ["name": .string("Bob"), "age": .int(25), "score": .double(3.8)])
        _ = try await store.addNode(label: "Person", properties: ["name": .string("Cath"), "age": .int(35), "score": .double(4.9)])
        _ = try await store.addNode(label: "Animal", properties: ["name": .string("Rex"), "age": .int(5)])
        return store
    }

    private func seedEdgeStore() async throws -> (GraphStore, NodeID, NodeID, NodeID) {
        let store = try await GraphStore.openInMemory()
        let a = try await store.addNode(label: "Person", properties: ["name": .string("Alice")])
        let b = try await store.addNode(label: "Person", properties: ["name": .string("Bob")])
        let c = try await store.addNode(label: "Person", properties: ["name": .string("Cath")])
        _ = try await store.addEdge(from: a, to: b, type: "KNOWS", properties: ["weight": .double(1.0), "since": .int(2020)])
        _ = try await store.addEdge(from: a, to: c, type: "KNOWS", properties: ["weight": .double(2.5), "since": .int(2022)])
        _ = try await store.addEdge(from: b, to: c, type: "WORKS_WITH", properties: ["weight": .double(3.0)])
        return (store, a, b, c)
    }

    // MARK: - NodeQuery aggregates

    func testNodeSum() async throws {
        let store = try await seedStore()
        let sum = try await store.nodes(labeled: "Person").sum(of: "age")
        XCTAssertEqual(sum, 90.0) // 30 + 25 + 35
    }

    func testNodeSumDouble() async throws {
        let store = try await seedStore()
        let sum = try await store.nodes(labeled: "Person").sum(of: "score")
        XCTAssertEqual(sum, 13.2, accuracy: 0.001)
    }

    func testNodeSumMissingProperty() async throws {
        let store = try await seedStore()
        let sum = try await store.nodes(labeled: "Person").sum(of: "nonexistent")
        XCTAssertEqual(sum, 0.0)
    }

    func testNodeAverage() async throws {
        let store = try await seedStore()
        let avg = try await store.nodes(labeled: "Person").average(of: "age")
        XCTAssertEqual(avg!, 30.0, accuracy: 0.001) // (30+25+35)/3
    }

    func testNodeAverageEmptyResult() async throws {
        let store = try await seedStore()
        let avg = try await store.nodes(labeled: "Nonexistent").average(of: "age")
        XCTAssertNil(avg)
    }

    func testNodeMin() async throws {
        let store = try await seedStore()
        let minVal = try await store.nodes(labeled: "Person").min(of: "age")
        XCTAssertEqual(minVal, .int(25))
    }

    func testNodeMax() async throws {
        let store = try await seedStore()
        let maxVal = try await store.nodes(labeled: "Person").max(of: "age")
        XCTAssertEqual(maxVal, .int(35))
    }

    func testNodeMinMaxEmpty() async throws {
        let store = try await seedStore()
        let minVal = try await store.nodes(labeled: "Nonexistent").min(of: "age")
        let maxVal = try await store.nodes(labeled: "Nonexistent").max(of: "age")
        XCTAssertNil(minVal)
        XCTAssertNil(maxVal)
    }

    func testNodeSumWithFilter() async throws {
        let store = try await seedStore()
        let sum = try await store.nodes(labeled: "Person")
            .where("age", .greaterThan, .int(25))
            .sum(of: "age")
        XCTAssertEqual(sum, 65.0) // 30 + 35
    }

    // MARK: - EdgeQuery aggregates

    func testEdgeSum() async throws {
        let (store, _, _, _) = try await seedEdgeStore()
        let sum = try await store.edgeQuery(type: "KNOWS").sum(of: "weight")
        XCTAssertEqual(sum, 3.5, accuracy: 0.001) // 1.0 + 2.5
    }

    func testEdgeAverage() async throws {
        let (store, _, _, _) = try await seedEdgeStore()
        let avg = try await store.edgeQuery(type: "KNOWS").average(of: "weight")
        XCTAssertEqual(avg!, 1.75, accuracy: 0.001)
    }

    func testEdgeMin() async throws {
        let (store, _, _, _) = try await seedEdgeStore()
        let minVal = try await store.edgeQuery(type: "KNOWS").min(of: "since")
        XCTAssertEqual(minVal, .int(2020))
    }

    func testEdgeMax() async throws {
        let (store, _, _, _) = try await seedEdgeStore()
        let maxVal = try await store.edgeQuery(type: "KNOWS").max(of: "weight")
        XCTAssertEqual(maxVal, .double(2.5))
    }

    func testEdgeSumWithFilter() async throws {
        let (store, _, _, _) = try await seedEdgeStore()
        let sum = try await store.edgeQuery(type: "KNOWS")
            .where("since", .greaterThan, .int(2020))
            .sum(of: "weight")
        XCTAssertEqual(sum, 2.5, accuracy: 0.001)
    }
}
