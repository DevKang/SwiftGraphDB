import XCTest
@testable import SwiftGraphDB

final class MultiLabelTests: XCTestCase {

    private func openStore() async throws -> GraphStore {
        try await GraphStore.openInMemory()
    }

    // MARK: - Backward compatibility

    func testSingleLabelBackwardCompat() async throws {
        let store = try await openStore()
        let id = try await store.addNode(label: "Person", properties: ["name": .string("Alice")])
        let nodes = try await store.nodes(labeled: "Person").collect()
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].label, "Person")
        XCTAssertEqual(nodes[0].labels, ["Person"])
    }

    // MARK: - Multi-label creation

    func testAddNodeWithMultipleLabels() async throws {
        let store = try await openStore()
        let id = try await store.addNode(labels: ["Person", "Employee"], properties: ["name": .string("Alice")])

        // Should be found by either label.
        let persons = try await store.nodes(labeled: "Person").collect()
        XCTAssertEqual(persons.count, 1)
        XCTAssertEqual(persons[0].id, id)

        let employees = try await store.nodes(labeled: "Employee").collect()
        XCTAssertEqual(employees.count, 1)
        XCTAssertEqual(employees[0].id, id)
    }

    func testMultiLabelNodeHasAllLabels() async throws {
        let store = try await openStore()
        _ = try await store.addNode(labels: ["Person", "Employee", "Manager"])
        let nodes = try await store.nodes(labeled: "Person").collect()
        XCTAssertEqual(nodes[0].labels, ["Person", "Employee", "Manager"])
    }

    // MARK: - Add label

    func testAddLabelToExistingNode() async throws {
        let store = try await openStore()
        let id = try await store.addNode(label: "Person")

        try await store.addLabel("Employee", to: id)

        let persons = try await store.nodes(labeled: "Person").collect()
        XCTAssertEqual(persons.count, 1)
        XCTAssertTrue(persons[0].labels.contains("Employee"))

        let employees = try await store.nodes(labeled: "Employee").collect()
        XCTAssertEqual(employees.count, 1)
        XCTAssertEqual(employees[0].id, id)
    }

    func testAddDuplicateLabelIsNoOp() async throws {
        let store = try await openStore()
        let id = try await store.addNode(label: "Person")

        try await store.addLabel("Person", to: id)

        let nodes = try await store.nodes(labeled: "Person").collect()
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].labels, ["Person"])
    }

    // MARK: - Remove label

    func testRemoveLabelFromNode() async throws {
        let store = try await openStore()
        let id = try await store.addNode(labels: ["Person", "Employee"])

        try await store.removeLabel("Employee", from: id)

        let persons = try await store.nodes(labeled: "Person").collect()
        XCTAssertEqual(persons.count, 1)
        XCTAssertEqual(persons[0].labels, ["Person"])

        let employees = try await store.nodes(labeled: "Employee").collect()
        XCTAssertEqual(employees.count, 0)
    }

    func testRemoveLastLabelThrows() async throws {
        let store = try await openStore()
        let id = try await store.addNode(label: "Person")

        do {
            try await store.removeLabel("Person", from: id)
            XCTFail("Expected error when removing last label")
        } catch is RepositoryError {
            // Expected
        }
    }

    func testRemoveNonexistentLabelIsNoOp() async throws {
        let store = try await openStore()
        let id = try await store.addNode(label: "Person")

        // Should not throw — the node just doesn't have this label.
        try await store.removeLabel("Employee", from: id)

        let nodes = try await store.nodes(labeled: "Person").collect()
        XCTAssertEqual(nodes.count, 1)
    }

    // MARK: - Query across labels

    func testQueryFindsNodeByAnyLabel() async throws {
        let store = try await openStore()
        _ = try await store.addNode(labels: ["Person", "Employee"], properties: ["name": .string("Alice")])
        _ = try await store.addNode(label: "Person", properties: ["name": .string("Bob")])
        _ = try await store.addNode(label: "Employee", properties: ["name": .string("Cath")])

        let persons = try await store.nodes(labeled: "Person").collect()
        XCTAssertEqual(persons.count, 2) // Alice + Bob

        let employees = try await store.nodes(labeled: "Employee").collect()
        XCTAssertEqual(employees.count, 2) // Alice + Cath
    }

    // MARK: - Mutation observation

    func testAddLabelEmitsNodeUpdated() async throws {
        let store = try await openStore()
        let id = try await store.addNode(label: "Person")
        let stream = await store.changes()

        try await store.addLabel("Employee", to: id)

        var mutations: [GraphMutation] = []
        let deadline = Date().addingTimeInterval(2.0)
        for await m in stream {
            mutations.append(m)
            if mutations.count >= 1 { break }
            if Date() > deadline { break }
        }

        XCTAssertEqual(mutations.count, 1)
        if case .nodeUpdated(let updatedID) = mutations[0] {
            XCTAssertEqual(updatedID, id)
        } else {
            XCTFail("Expected .nodeUpdated")
        }
    }

    // MARK: - Persistence across reopen

    func testMultiLabelSurvivesRebuild() async throws {
        let store = try await openStore()
        let id = try await store.addNode(labels: ["Person", "Employee"])

        // Force a rebuild from SQLite
        let actor = store.actor
        try await actor.rebuild()

        let nodes = try await store.nodes(labeled: "Person").collect()
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].labels, ["Person", "Employee"])

        let employees = try await store.nodes(labeled: "Employee").collect()
        XCTAssertEqual(employees.count, 1)
    }
}
