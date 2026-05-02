import XCTest
@testable import SwiftGraphDB

final class ShortestPathTests: XCTestCase {

    func testDirectEdgePathIsLength1() async throws {
        let graph = try await GraphStore.openInMemory()
        let a = try await graph.addNode(label: "P")
        let b = try await graph.addNode(label: "P")
        try await graph.addEdge(from: a, to: b, type: "L")

        let path = try await graph.shortestPath(from: a, to: b)
        XCTAssertEqual(path?.length, 1)
        XCTAssertEqual(path?.nodes.map(\.id), [a, b])
    }

    func testIndirectPathThroughMiddleNode() async throws {
        let graph = try await GraphStore.openInMemory()
        let a = try await graph.addNode(label: "P")
        let b = try await graph.addNode(label: "P")
        let c = try await graph.addNode(label: "P")
        try await graph.addEdge(from: a, to: c, type: "L")
        try await graph.addEdge(from: c, to: b, type: "L")

        let path = try await graph.shortestPath(from: a, to: b)
        XCTAssertEqual(path?.length, 2)
        XCTAssertEqual(path?.nodes.map(\.id), [a, c, b])
    }

    func testNoPathReturnsNil() async throws {
        let graph = try await GraphStore.openInMemory()
        let a = try await graph.addNode(label: "P")
        let b = try await graph.addNode(label: "P")
        let path = try await graph.shortestPath(from: a, to: b)
        XCTAssertNil(path)
    }

    func testViaTypeFilter() async throws {
        let graph = try await GraphStore.openInMemory()
        let a = try await graph.addNode(label: "P")
        let b = try await graph.addNode(label: "P")
        try await graph.addEdge(from: a, to: b, type: "REFERENCES")

        let knows = try await graph.shortestPath(from: a, to: b, via: "KNOWS")
        XCTAssertNil(knows)
        let refs = try await graph.shortestPath(from: a, to: b, via: "REFERENCES")
        XCTAssertEqual(refs?.length, 1)
    }

    func testSelfPathHasLengthZero() async throws {
        let graph = try await GraphStore.openInMemory()
        let a = try await graph.addNode(label: "P")
        let path = try await graph.shortestPath(from: a, to: a)
        XCTAssertEqual(path?.length, 0)
        XCTAssertEqual(path?.nodes.count, 1)
    }

    func testLineGraph100Nodes() async throws {
        let graph = try await GraphStore.openInMemory()
        var ids: [NodeID] = []
        for _ in 0..<100 {
            ids.append(try await graph.addNode(label: "P"))
        }
        for i in 0..<99 {
            try await graph.addEdge(from: ids[i], to: ids[i+1], type: "L")
        }
        let path = try await graph.shortestPath(from: ids[0], to: ids[99])
        XCTAssertEqual(path?.length, 99)
    }

    func testTiedPathsAreInsertionOrderDeterministic() async throws {
        // Two parallel paths A → X → C and A → Y → C; edge from A→X added first.
        let graph = try await GraphStore.openInMemory()
        let a = try await graph.addNode(label: "P")
        let x = try await graph.addNode(label: "P")
        let y = try await graph.addNode(label: "P")
        let c = try await graph.addNode(label: "P")
        try await graph.addEdge(from: a, to: x, type: "L")
        try await graph.addEdge(from: a, to: y, type: "L")
        try await graph.addEdge(from: x, to: c, type: "L")
        try await graph.addEdge(from: y, to: c, type: "L")

        let path = try await graph.shortestPath(from: a, to: c)
        XCTAssertEqual(path?.length, 2)
        XCTAssertEqual(path?.nodes[1].id, x, "first-inserted edge wins the tie")
    }
}
