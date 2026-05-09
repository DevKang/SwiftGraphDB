import XCTest
@_spi(Internal) @testable import SwiftGraphDB

final class SQLQueryTests: XCTestCase {

    private func seedStore() async throws -> GraphStore {
        let store = try await GraphStore.openInMemory()
        _ = try await store.addNode(label: "Person", properties: [
            "name": .string("Alice"), "age": .int(32), "city": .string("Seoul"),
        ])
        _ = try await store.addNode(label: "Person", properties: [
            "name": .string("Bob"), "age": .int(28), "city": .string("Busan"),
        ])
        _ = try await store.addNode(label: "Person", properties: [
            "name": .string("Cath"), "age": .int(35), "city": .string("Seoul"),
        ])
        _ = try await store.addNode(label: "Person", properties: [
            "name": .string("Dee"), "age": .int(24), "city": .string("Incheon"),
        ])
        _ = try await store.addNode(label: "Person", properties: [
            "name": .string("Eli"), "age": .int(30), "city": .string("Daegu"),
        ])
        return store
    }

    // MARK: - Sorted

    func testSortedByNameAscending() async throws {
        let store = try await seedStore()
        let nodes = try await store.nodes(labeled: "Person")
            .sorted(by: "name", .ascending)
            .collect()
        let names = nodes.compactMap { node -> String? in
            if case .string(let s) = node.properties["name"] { return s }
            return nil
        }
        XCTAssertEqual(names, ["Alice", "Bob", "Cath", "Dee", "Eli"])
    }

    func testSortedByAgeDescending() async throws {
        let store = try await seedStore()
        let nodes = try await store.nodes(labeled: "Person")
            .sorted(by: "age", .descending)
            .collect()
        let ages = nodes.compactMap { node -> Int64? in
            if case .int(let i) = node.properties["age"] { return i }
            return nil
        }
        XCTAssertEqual(ages, [35, 32, 30, 28, 24])
    }

    // MARK: - Limit / Offset

    func testLimitReturnsAtMostNNodes() async throws {
        let store = try await seedStore()
        let nodes = try await store.nodes(labeled: "Person")
            .sorted(by: "name")
            .limit(3)
            .collect()
        XCTAssertEqual(nodes.count, 3)
    }

    func testLimitWithOffset() async throws {
        let store = try await seedStore()
        let nodes = try await store.nodes(labeled: "Person")
            .sorted(by: "name")
            .limit(2, offset: 2)
            .collect()
        let names = nodes.compactMap { n -> String? in
            if case .string(let s) = n.properties["name"] { return s }
            return nil
        }
        XCTAssertEqual(names, ["Cath", "Dee"])
    }

    // MARK: - SQL Where

    func testSqlWhereEquals() async throws {
        let store = try await seedStore()
        let nodes = try await store.nodes(labeled: "Person")
            .where("city", .equals, .string("Seoul"))
            .sorted(by: "name")
            .collect()
        let names = nodes.compactMap { n -> String? in
            if case .string(let s) = n.properties["name"] { return s }
            return nil
        }
        XCTAssertEqual(names, ["Alice", "Cath"])
    }

    func testSqlWhereGreaterThan() async throws {
        let store = try await seedStore()
        let nodes = try await store.nodes(labeled: "Person")
            .where("age", .greaterThan, .int(30))
            .sorted(by: "age")
            .collect()
        let ages = nodes.compactMap { n -> Int64? in
            if case .int(let i) = n.properties["age"] { return i }
            return nil
        }
        XCTAssertEqual(ages, [32, 35])
    }

    func testSqlWhereLessThanOrEqual() async throws {
        let store = try await seedStore()
        let nodes = try await store.nodes(labeled: "Person")
            .where("age", .lessThanOrEqual, .int(28))
            .sorted(by: "age")
            .collect()
        let ages = nodes.compactMap { n -> Int64? in
            if case .int(let i) = n.properties["age"] { return i }
            return nil
        }
        XCTAssertEqual(ages, [24, 28])
    }

    // MARK: - Contains

    func testWhereContains() async throws {
        let store = try await seedStore()
        let nodes = try await store.nodes(labeled: "Person")
            .where("name", contains: "li")
            .sorted(by: "name")
            .collect()
        let names = nodes.compactMap { n -> String? in
            if case .string(let s) = n.properties["name"] { return s }
            return nil
        }
        // "Alice" and "Eli" both contain "li"
        XCTAssertEqual(names, ["Alice", "Eli"])
    }

    func testWhereContainsWithSpecialCharacters() async throws {
        let store = try await GraphStore.openInMemory()
        _ = try await store.addNode(label: "Doc", properties: [
            "title": .string("100% done"),
        ])
        _ = try await store.addNode(label: "Doc", properties: [
            "title": .string("half done"),
        ])
        let nodes = try await store.nodes(labeled: "Doc")
            .where("title", contains: "100%")
            .collect()
        XCTAssertEqual(nodes.count, 1)
    }

    // MARK: - Chained queries

    func testChainedFilterSortLimit() async throws {
        let store = try await seedStore()
        let nodes = try await store.nodes(labeled: "Person")
            .where("age", .greaterThanOrEqual, .int(28))
            .sorted(by: "age", .descending)
            .limit(2)
            .collect()
        let names = nodes.compactMap { n -> String? in
            if case .string(let s) = n.properties["name"] { return s }
            return nil
        }
        // age >= 28: Cath(35), Alice(32), Eli(30), Bob(28). Top 2 desc: Cath, Alice
        XCTAssertEqual(names, ["Cath", "Alice"])
    }

    // MARK: - Existing where still works

    func testLegacyClosureWhereStillWorks() async throws {
        let store = try await seedStore()
        let nodes = try await store.nodes(labeled: "Person")
            .where { node in
                if case .string(let city) = node.properties["city"] {
                    return city == "Seoul"
                }
                return false
            }
            .collect()
        XCTAssertEqual(nodes.count, 2)
    }

    // MARK: - json_extract verification

    func testJsonExtractWorksDirectly() async throws {
        let store = try await seedStore()
        let sqlStore = await store.storeForQueriesUnsafe
        let names = try sqlStore.query(
            "SELECT json_extract(properties, '$.name.value') FROM nodes WHERE is_deleted = 0 ORDER BY json_extract(properties, '$.name.value')"
        ) { $0.text(at: 0)! }
        XCTAssertEqual(names, ["Alice", "Bob", "Cath", "Dee", "Eli"])
    }
}
