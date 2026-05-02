import XCTest
@testable import SwiftGraphDB

final class SourceOperationTests: XCTestCase {

    private func seededGraph() async throws -> (GraphStore, [NodeID]) {
        let graph = try await GraphStore.openInMemory()
        var ids: [NodeID] = []
        for i in 0..<10 {
            let id = try await graph.addNode(label: "Person", properties: ["age": .int(Int64(20 + i))])
            ids.append(id)
        }
        for _ in 0..<5 {
            _ = try await graph.addNode(label: "Concept", properties: ["name": "x"])
        }
        return (graph, ids)
    }

    func testNodesLabeledReturnsExactlyTheLabel() async throws {
        let (graph, _) = try await seededGraph()
        let people = try await graph.nodes(labeled: "Person").collect()
        let concepts = try await graph.nodes(labeled: "Concept").collect()
        XCTAssertEqual(people.count, 10)
        XCTAssertEqual(concepts.count, 5)
        XCTAssertTrue(people.allSatisfy { $0.label == "Person" })
    }

    func testNodeByIDReturnsOneIfPresent() async throws {
        let (graph, ids) = try await seededGraph()
        let single = try await graph.node(id: ids[0]).collect()
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.first?.id, ids[0])
    }

    func testNodeByUnknownIDReturnsEmpty() async throws {
        let graph = try await GraphStore.openInMemory()
        let result = try await graph.node(id: IDFactory.live.nodeID()).collect()
        XCTAssertTrue(result.isEmpty)
    }

    func testNodesWhereGreaterThanReturnsExpectedSubset() async throws {
        let (graph, _) = try await seededGraph()
        let above = try await graph.nodes(where: "age", greaterThan: .int(25)).collect()
        XCTAssertEqual(above.count, 4, "ages 26..29 are > 25")
    }

    func testNodesLabeledOnUnknownLabelReturnsEmpty() async throws {
        let graph = try await GraphStore.openInMemory()
        let result = try await graph.nodes(labeled: "Nope").collect()
        XCTAssertTrue(result.isEmpty)
    }

    func testCountShortCircuitsOnLabelIndex() async throws {
        let (graph, _) = try await seededGraph()
        let count = try await graph.nodes(labeled: "Person").count()
        XCTAssertEqual(count, 10)
    }
}
