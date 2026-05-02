import XCTest
@testable import SwiftGraphDB

final class TraversalTests: XCTestCase {

    /// 5-node fixture:
    ///   A → B
    ///   A → C
    ///   B → C
    ///   C → D
    ///   D → E
    private func fixture() async throws -> (GraphStore, [String: NodeID]) {
        let graph = try await GraphStore.openInMemory()
        var ids: [String: NodeID] = [:]
        for name in ["A", "B", "C", "D", "E"] {
            ids[name] = try await graph.addNode(label: "Person", properties: ["name": .string(name)])
        }
        try await graph.addEdge(from: ids["A"]!, to: ids["B"]!, type: "KNOWS")
        try await graph.addEdge(from: ids["A"]!, to: ids["C"]!, type: "KNOWS")
        try await graph.addEdge(from: ids["B"]!, to: ids["C"]!, type: "KNOWS")
        try await graph.addEdge(from: ids["C"]!, to: ids["D"]!, type: "KNOWS")
        try await graph.addEdge(from: ids["D"]!, to: ids["E"]!, type: "KNOWS")
        return (graph, ids)
    }

    func test1HopOutgoingFromAReturnsBAndC() async throws {
        let (graph, ids) = try await fixture()
        let result = try await graph.node(id: ids["A"]!)
            .traverse(.outgoing, edge: "KNOWS")
            .collect()
        XCTAssertEqual(Set(result.map(\.id)), [ids["B"]!, ids["C"]!])
    }

    func test2HopOutgoingFromAExpands() async throws {
        let (graph, ids) = try await fixture()
        let result = try await graph.node(id: ids["A"]!)
            .traverse(.outgoing, edge: "KNOWS", maxDepth: .bounded(2))
            .collect()
        XCTAssertEqual(Set(result.map(\.id)), [ids["B"]!, ids["C"]!, ids["D"]!])
    }

    func testCyclicGraphTerminates() async throws {
        let graph = try await GraphStore.openInMemory()
        let a = try await graph.addNode(label: "Person")
        let b = try await graph.addNode(label: "Person")
        try await graph.addEdge(from: a, to: b, type: "L")
        try await graph.addEdge(from: b, to: a, type: "L")

        let result = try await graph.node(id: a)
            .traverse(.outgoing, edge: "L", maxDepth: .unlimited)
            .collect()
        XCTAssertEqual(Set(result.map(\.id)), [b])
    }

    func testIncomingDirection() async throws {
        let (graph, ids) = try await fixture()
        let result = try await graph.node(id: ids["C"]!)
            .traverse(.incoming, edge: "KNOWS")
            .collect()
        XCTAssertEqual(Set(result.map(\.id)), [ids["A"]!, ids["B"]!])
    }

    func testBothDirectionVisitsForwardAndReverse() async throws {
        let (graph, ids) = try await fixture()
        let result = try await graph.node(id: ids["C"]!)
            .traverse(.both, edge: "KNOWS")
            .collect()
        XCTAssertEqual(Set(result.map(\.id)), [ids["A"]!, ids["B"]!, ids["D"]!])
    }

    func testEdgeTypeFilterExcludesOtherTypes() async throws {
        let graph = try await GraphStore.openInMemory()
        let a = try await graph.addNode(label: "Person")
        let b = try await graph.addNode(label: "Person")
        let c = try await graph.addNode(label: "Person")
        try await graph.addEdge(from: a, to: b, type: "KNOWS")
        try await graph.addEdge(from: a, to: c, type: "REFERENCES")

        let knows = try await graph.node(id: a)
            .traverse(.outgoing, edge: "KNOWS")
            .collect()
        XCTAssertEqual(Set(knows.map(\.id)), [b])
    }

    func testSoftDeletedEdgeNotTraversed() async throws {
        let graph = try await GraphStore.openInMemory()
        let a = try await graph.addNode(label: "Person")
        let b = try await graph.addNode(label: "Person")
        let edgeID = try await graph.addEdge(from: a, to: b, type: "L")
        try await graph.deleteEdge(id: edgeID)

        let result = try await graph.node(id: a)
            .traverse(.outgoing, edge: "L")
            .collect()
        XCTAssertTrue(result.isEmpty)
    }
}
