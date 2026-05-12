import XCTest
@testable import SwiftGraphDB

final class EdgeQueryTests: XCTestCase {

    private func seedStore() async throws -> (GraphStore, NodeID, NodeID, NodeID) {
        let store = try await GraphStore.openInMemory()
        let a = try await store.addNode(label: "Person", properties: ["name": .string("Alice")])
        let b = try await store.addNode(label: "Person", properties: ["name": .string("Bob")])
        let c = try await store.addNode(label: "Person", properties: ["name": .string("Cath")])

        _ = try await store.addEdge(from: a, to: b, type: "KNOWS", properties: ["since": .int(2020), "weight": .double(1.0)])
        _ = try await store.addEdge(from: a, to: c, type: "KNOWS", properties: ["since": .int(2022), "weight": .double(2.5)])
        _ = try await store.addEdge(from: b, to: c, type: "WORKS_WITH", properties: ["since": .int(2021), "dept": .string("Engineering")])
        return (store, a, b, c)
    }

    // MARK: - Source operations

    func testEdgesTypedReturnsOnlyMatchingType() async throws {
        let (store, _, _, _) = try await seedStore()
        let edges = try await store.edgeQuery(type: "KNOWS").collect()
        XCTAssertEqual(edges.count, 2)
        XCTAssertTrue(edges.allSatisfy { $0.type == "KNOWS" })
    }

    func testEdgesFromNodeReturnsOutgoing() async throws {
        let (store, a, _, _) = try await seedStore()
        let edges = try await store.edgeQuery(from: a).collect()
        XCTAssertEqual(edges.count, 2)
        XCTAssertTrue(edges.allSatisfy { $0.fromID == a })
    }

    func testEdgesToNodeReturnsIncoming() async throws {
        let (store, _, _, c) = try await seedStore()
        let edges = try await store.edgeQuery(to: c).collect()
        XCTAssertEqual(edges.count, 2)
        XCTAssertTrue(edges.allSatisfy { $0.toID == c })
    }

    // MARK: - SQL where

    func testWhereFiltersByProperty() async throws {
        let (store, _, _, _) = try await seedStore()
        let edges = try await store.edgeQuery(type: "KNOWS")
            .where("since", .greaterThan, .int(2020))
            .collect()
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].properties["since"], .int(2022))
    }

    func testWhereEquals() async throws {
        let (store, _, _, _) = try await seedStore()
        let edges = try await store.edgeQuery(type: "WORKS_WITH")
            .where("dept", .equals, .string("Engineering"))
            .collect()
        XCTAssertEqual(edges.count, 1)
    }

    // MARK: - Contains

    func testWhereContains() async throws {
        let (store, _, _, _) = try await seedStore()
        let edges = try await store.edgeQuery(type: "WORKS_WITH")
            .where("dept", contains: "gin")
            .collect()
        XCTAssertEqual(edges.count, 1)
    }

    // MARK: - Sorted

    func testSortedByProperty() async throws {
        let (store, _, _, _) = try await seedStore()
        let edges = try await store.edgeQuery(type: "KNOWS")
            .sorted(by: "since", .descending)
            .collect()
        let years = edges.compactMap { e -> Int64? in
            if case .int(let i) = e.properties["since"] { return i }
            return nil
        }
        XCTAssertEqual(years, [2022, 2020])
    }

    // MARK: - Limit

    func testLimitReturnsAtMostN() async throws {
        let (store, _, _, _) = try await seedStore()
        let edges = try await store.edgeQuery(type: "KNOWS")
            .sorted(by: "since")
            .limit(1)
            .collect()
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].properties["since"], .int(2020))
    }

    // MARK: - Chained

    func testChainedFilterSortLimit() async throws {
        let (store, _, _, _) = try await seedStore()
        let edges = try await store.edgeQuery(type: "KNOWS")
            .where("weight", .greaterThanOrEqual, .double(1.0))
            .sorted(by: "weight", .descending)
            .limit(1)
            .collect()
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].properties["weight"], .double(2.5))
    }

    // MARK: - Terminal operations

    func testCount() async throws {
        let (store, _, _, _) = try await seedStore()
        let count = try await store.edgeQuery(type: "KNOWS").count()
        XCTAssertEqual(count, 2)
    }

    func testFirst() async throws {
        let (store, _, _, _) = try await seedStore()
        let edge = try await store.edgeQuery(type: "WORKS_WITH").first()
        XCTAssertNotNil(edge)
        XCTAssertEqual(edge?.type, "WORKS_WITH")
    }

    func testExists() async throws {
        let (store, _, _, _) = try await seedStore()
        let exists = try await store.edgeQuery(type: "KNOWS").exists()
        XCTAssertTrue(exists)

        let none = try await store.edgeQuery(type: "NONEXISTENT").exists()
        XCTAssertFalse(none)
    }

    // MARK: - Closure filter (legacy path)

    func testClosureFilterFallsBackToLegacy() async throws {
        let (store, _, _, _) = try await seedStore()
        let edges = try await store.edgeQuery(type: "KNOWS")
            .where { edge in
                if case .double(let w) = edge.properties["weight"] {
                    return w > 1.5
                }
                return false
            }
            .collect()
        XCTAssertEqual(edges.count, 1)
    }
}
