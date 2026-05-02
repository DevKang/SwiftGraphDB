import XCTest
@testable import SwiftGraphDB

final class FilterTests: XCTestCase {

    private func seededGraph() async throws -> GraphStore {
        let graph = try await GraphStore.openInMemory()
        for i in 0..<10 {
            _ = try await graph.addNode(label: "Person", properties: [
                "age": .int(Int64(20 + i)),
                "city": .string(i.isMultiple(of: 2) ? "Seoul" : "Busan"),
            ])
        }
        return graph
    }

    func testEqualsFilter() async throws {
        let graph = try await seededGraph()
        let seoul = try await graph.nodes(labeled: "Person")
            .where("city", equals: .string("Seoul"))
            .collect()
        XCTAssertEqual(seoul.count, 5)
    }

    func testGreaterThanFilter() async throws {
        let graph = try await seededGraph()
        let above = try await graph.nodes(labeled: "Person")
            .where("age", greaterThan: .int(25))
            .collect()
        XCTAssertEqual(above.count, 4)
    }

    func testLessThanFilter() async throws {
        let graph = try await seededGraph()
        let below = try await graph.nodes(labeled: "Person")
            .where("age", lessThan: .int(25))
            .collect()
        XCTAssertEqual(below.count, 5)
    }

    func testInFilter() async throws {
        let graph = try await seededGraph()
        let inSet = try await graph.nodes(labeled: "Person")
            .where("age", in: [.int(20), .int(21), .int(99)])
            .collect()
        XCTAssertEqual(inSet.count, 2)
    }

    func testCrossTypeComparisonReturnsEmpty() async throws {
        let graph = try await seededGraph()
        let mismatched = try await graph.nodes(labeled: "Person")
            .where("age", greaterThan: .string("hello"))
            .collect()
        XCTAssertTrue(mismatched.isEmpty, "int vs string is incomparable → no matches")
    }

    func testChainedWhereIsAnd() async throws {
        let graph = try await seededGraph()
        let result = try await graph.nodes(labeled: "Person")
            .where("city", equals: .string("Seoul"))
            .where("age", greaterThan: .int(22))
            .collect()
        // Seoul = even i ∈ {0,2,4,6,8} → ages {20,22,24,26,28}. age>22 → {24,26,28} = 3.
        XCTAssertEqual(result.count, 3)
    }

    func testEscapeHatchClosure() async throws {
        let graph = try await seededGraph()
        let result = try await graph.nodes(labeled: "Person")
            .where { $0.properties["age"] == .int(25) }
            .collect()
        XCTAssertEqual(result.count, 1)
    }
}
