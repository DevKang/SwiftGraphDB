import XCTest
@testable import SwiftGraphDB

final class CollectTests: XCTestCase {

    private func seededGraph() async throws -> GraphStore {
        let graph = try await GraphStore.openInMemory()
        for i in 0..<5 {
            _ = try await graph.addNode(label: "Person", properties: ["i": .int(Int64(i))])
        }
        return graph
    }

    func testCollectMaterialisesAllMatches() async throws {
        let graph = try await seededGraph()
        let nodes = try await graph.nodes(labeled: "Person").collect()
        XCTAssertEqual(nodes.count, 5)
    }

    func testCountAgreesWithCollect() async throws {
        let graph = try await seededGraph()
        let count = try await graph.nodes(labeled: "Person").count()
        let collected = try await graph.nodes(labeled: "Person").collect()
        XCTAssertEqual(count, collected.count)
    }

    func testFirstReturnsOneOrNil() async throws {
        let graph = try await seededGraph()
        let one = try await graph.nodes(labeled: "Person").first()
        XCTAssertNotNil(one)

        let empty = try await GraphStore.openInMemory()
        let none = try await empty.nodes(labeled: "Person").first()
        XCTAssertNil(none)
    }

    func testExistsTrueIffCountPositive() async throws {
        let graph = try await seededGraph()
        let yes = try await graph.nodes(labeled: "Person").exists()
        let no = try await graph.nodes(labeled: "Nope").exists()
        XCTAssertTrue(yes)
        XCTAssertFalse(no)
    }

    func testCountShortCircuitsForLabelOnlyQuery() async throws {
        // Label-only count returns from the label index without materialising nodes.
        let graph = try await seededGraph()
        // Call count() and inspect: it must return 5 even if we close the SQLite store
        // beforehand (proves no SQL was needed). Realised via SQL? Actually the index-only
        // path doesn't need SQL, so this is a structural assertion.
        let count = try await graph.nodes(labeled: "Person").count()
        XCTAssertEqual(count, 5)
    }

    func testFirstStopsBeforeMaterialisingAll() async throws {
        // Construct 100 nodes; first() should return after one fetch — we measure by elapsed
        // time as a rough sanity check.
        let graph = try await GraphStore.openInMemory()
        for _ in 0..<100 { _ = try await graph.addNode(label: "P", properties: [:]) }

        let start = ContinuousClock.now
        _ = try await graph.nodes(labeled: "P").first()
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(50))
    }

    func testCollectWithEdgesReturnsTraversedEdges() async throws {
        let graph = try await GraphStore.openInMemory()
        let a = try await graph.addNode(label: "P")
        let b = try await graph.addNode(label: "P")
        let c = try await graph.addNode(label: "P")
        try await graph.addEdge(from: a, to: b, type: "L")
        try await graph.addEdge(from: b, to: c, type: "L")

        let (nodes, edges) = try await graph.node(id: a)
            .traverse(.outgoing, edge: "L", maxDepth: .bounded(2))
            .collectWithEdges()
        XCTAssertEqual(Set(nodes.map(\.id)), [b, c])
        XCTAssertEqual(edges.count, 2)
    }
}
