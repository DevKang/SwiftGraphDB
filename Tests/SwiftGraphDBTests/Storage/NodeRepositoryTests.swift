import XCTest
@testable import SwiftGraphDB

final class NodeRepositoryTests: XCTestCase {
    private let testActor = ActorID()
    private var counter: Int64 = 0
    private func nextRev() -> GraphRevision {
        counter += 1
        return GraphRevision(actorID: testActor, counter: counter, wallClock: Date())
    }


    // MARK: - Insert + fetch

    func testInsertThenFetchReturnsEqualNode() throws {
        let (store, repo) = try makeRepo()
        defer { store.close() }

        let node = Node(label: "Person", properties: ["name": "Alice", "age": 32])
        try repo.insert(node)

        let fetched = try repo.fetch(id: node.id)
        XCTAssertEqual(fetched?.id, node.id)
        XCTAssertEqual(fetched?.label, node.label)
        XCTAssertEqual(fetched?.properties, node.properties)
    }

    func testFetchMissingIDReturnsNil() throws {
        let (store, repo) = try makeRepo()
        defer { store.close() }
        let nothing = try repo.fetch(id: IDFactory.live.nodeID())
        XCTAssertNil(nothing)
    }

    func testInsertingDuplicateIDThrows() throws {
        let (store, repo) = try makeRepo()
        defer { store.close() }
        let id = IDFactory.live.nodeID()
        try repo.insert(Node(id: id, label: "Person"))
        XCTAssertThrowsError(try repo.insert(Node(id: id, label: "Concept")))
    }

    // MARK: - fetchAll(label:)

    func testFetchAllByLabelReturnsOnlyMatching() throws {
        let (store, repo) = try makeRepo()
        defer { store.close() }
        try repo.insert(Node(label: "Person", properties: ["name": "Alice"]))
        try repo.insert(Node(label: "Person", properties: ["name": "Bob"]))
        try repo.insert(Node(label: "Concept", properties: ["name": "Graph"]))

        let people = try repo.fetchAll(label: "Person")
        XCTAssertEqual(people.count, 2)
        XCTAssertTrue(people.allSatisfy { $0.label == "Person" })
    }

    func testFetchAllExcludesSoftDeleted() throws {
        let (store, repo) = try makeRepo()
        defer { store.close() }
        let alice = Node(label: "Person", properties: ["name": "Alice"])
        try repo.insert(alice)
        try repo.insert(Node(label: "Person", properties: ["name": "Bob"]))

        try repo.delete(id: alice.id, revision: nextRev())

        let people = try repo.fetchAll(label: "Person")
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people.first?.properties["name"], "Bob")
    }

    // MARK: - Update

    func testUpdateMergesPropertiesAndBumpsModifiedAt() throws {
        let (store, repo) = try makeRepo()
        defer { store.close() }
        let original = Node(label: "Person", properties: ["name": "Alice", "age": 32])
        try repo.insert(original)

        Thread.sleep(forTimeInterval: 0.01)
        try repo.update(id: original.id, properties: ["age": 33, "email": "a@example.com"], revision: nextRev())

        let updated = try repo.fetch(id: original.id)!
        XCTAssertEqual(updated.properties["name"], "Alice")
        XCTAssertEqual(updated.properties["age"], 33)
        XCTAssertEqual(updated.properties["email"], "a@example.com")
        XCTAssertGreaterThan(updated.modifiedAt, original.modifiedAt)
    }

    func testUpdateWithNullRemovesKey() throws {
        let (store, repo) = try makeRepo()
        defer { store.close() }
        let node = Node(label: "Person", properties: ["name": "Alice", "age": 32, "temp": "remove-me"])
        try repo.insert(node)

        try repo.update(id: node.id, properties: ["temp": .null], revision: nextRev())

        let updated = try repo.fetch(id: node.id)!
        XCTAssertEqual(updated.properties["name"], "Alice")
        XCTAssertEqual(updated.properties["age"], 32)
        XCTAssertNil(updated.properties["temp"], ".null should remove the key")
    }

    // MARK: - Delete

    func testSoftDeleteHidesNodeFromFetch() throws {
        let (store, repo) = try makeRepo()
        defer { store.close() }
        let n = Node(label: "Person", properties: ["name": "Alice"])
        try repo.insert(n)

        try repo.delete(id: n.id, revision: nextRev())

        XCTAssertNil(try repo.fetch(id: n.id))
    }

    // MARK: - Persistence

    func testDataSurvivesCloseAndReopen() throws {
        let url = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let id: NodeID
        do {
            let store = try SQLiteStore(at: url)
            try MigrationRunner.runDefault(on: store)
            let repo = NodeRepository(store: store)
            let n = Node(label: "Person", properties: ["name": "Alice"])
            try repo.insert(n)
            id = n.id
            store.close()
        }

        let store = try SQLiteStore(at: url)
        defer { store.close() }
        try MigrationRunner.runDefault(on: store)
        let repo = NodeRepository(store: store)

        let fetched = try repo.fetch(id: id)
        XCTAssertEqual(fetched?.properties["name"], "Alice")
    }

    // MARK: - Determinism of property BLOB

    func testPropertyTextIsDeterministicAcrossInserts() throws {
        let (store, repo) = try makeRepo()
        defer { store.close() }

        let a = Node(label: "Person", properties: ["name": "Alice", "age": 32])
        let b = Node(label: "Person", properties: ["name": "Alice", "age": 32])
        try repo.insert(a)
        try repo.insert(b)

        let texts = try store.query("SELECT properties FROM nodes ORDER BY id") { $0.text(at: 0)! }
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(texts[0], texts[1], "equal property dictionaries should produce equal JSON TEXT")
    }

    // MARK: - Helpers

    private func makeRepo() throws -> (SQLiteStore, NodeRepository) {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        return (store, NodeRepository(store: store))
    }

    private func tempStoreURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftGraphDB-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.sqlite")
    }
}
