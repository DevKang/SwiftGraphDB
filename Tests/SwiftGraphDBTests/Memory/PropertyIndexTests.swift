import XCTest
@testable import SwiftGraphDB

final class PropertyIndexTests: XCTestCase {

    // MARK: - Declaration + populate

    func testInsertPopulatesDeclaredIndex() {
        let spec = PropertyIndexSpec(label: "Person", property: "email")
        var index = PropertyIndex(specs: [spec])

        let alice = Node(label: "Person", properties: ["email": "a@example.com"])
        let bob = Node(label: "Person", properties: ["email": "b@example.com"])

        index.insert(alice)
        index.insert(bob)

        XCTAssertEqual(
            index.nodes(label: "Person", property: "email", equals: "a@example.com"),
            [alice.id]
        )
    }

    func testQueryAgainstUndeclaredPropertyReturnsNil() {
        let index = PropertyIndex(specs: [PropertyIndexSpec(label: "Person", property: "email")])
        XCTAssertNil(index.nodes(label: "Person", property: "name", equals: "Alice"))
    }

    func testQueryWithDifferentLabelButSamePropertyReturnsNil() {
        var index = PropertyIndex(specs: [PropertyIndexSpec(label: "Person", property: "email")])
        let n = Node(label: "Concept", properties: ["email": "x@example.com"])
        index.insert(n)
        XCTAssertNil(index.nodes(label: "Concept", property: "email", equals: "x@example.com"))
    }

    // MARK: - Update moves atomically

    func testUpdateMovesNodeAtomically() {
        let spec = PropertyIndexSpec(label: "Person", property: "email")
        var index = PropertyIndex(specs: [spec])
        let alice = Node(label: "Person", properties: ["email": "old@example.com"])
        index.insert(alice)

        let updated = alice.with(properties: ["email": "new@example.com"])
        index.update(from: alice, to: updated)

        XCTAssertNil(index.nodes(label: "Person", property: "email", equals: "old@example.com")?.first(where: { _ in true }))
        XCTAssertEqual(
            index.nodes(label: "Person", property: "email", equals: "old@example.com"),
            []
        )
        XCTAssertEqual(
            index.nodes(label: "Person", property: "email", equals: "new@example.com"),
            [alice.id]
        )
    }

    // MARK: - Delete

    func testDeleteRemovesFromIndex() {
        let spec = PropertyIndexSpec(label: "Person", property: "email")
        var index = PropertyIndex(specs: [spec])
        let alice = Node(label: "Person", properties: ["email": "a@example.com"])
        index.insert(alice)
        index.delete(alice)

        XCTAssertEqual(
            index.nodes(label: "Person", property: "email", equals: "a@example.com"),
            []
        )
    }

    // MARK: - Rebuild matches incremental

    func testRebuildMatchesIncrementalIndex() {
        let spec = PropertyIndexSpec(label: "Person", property: "email")

        let people = (0..<10).map { i in
            Node(label: "Person", properties: ["email": .string("p\(i)@example.com")])
        }

        var incremental = PropertyIndex(specs: [spec])
        for n in people { incremental.insert(n) }

        let rebuilt = PropertyIndex(specs: [spec], from: people)

        for n in people {
            let email = n.properties["email"]!
            XCTAssertEqual(
                rebuilt.nodes(label: "Person", property: "email", equals: email),
                incremental.nodes(label: "Person", property: "email", equals: email)
            )
        }
    }

    // MARK: - Spec-not-declared variants are silently ignored on writes

    func testInsertOfNonIndexedNodeIsNoOp() {
        let spec = PropertyIndexSpec(label: "Person", property: "email")
        var index = PropertyIndex(specs: [spec])
        let concept = Node(label: "Concept", properties: ["email": "x@example.com"])
        index.insert(concept) // does not crash, does not throw
        XCTAssertNil(index.nodes(label: "Concept", property: "email", equals: "x@example.com"))
    }

    func testEmptySpecListIsNoOp() {
        var index = PropertyIndex(specs: [])
        let alice = Node(label: "Person", properties: ["email": "a@example.com"])
        index.insert(alice)
        XCTAssertNil(index.nodes(label: "Person", property: "email", equals: "a@example.com"))
    }
}
