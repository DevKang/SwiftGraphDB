import XCTest
@testable import SwiftGraphDB

/// Mutable counter usable from `@Sendable` closures in tests.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var e = 0
    func bumpNodes() { lock.lock(); n += 1; lock.unlock() }
    func bumpEdges() { lock.lock(); e += 1; lock.unlock() }
    var nodes: Int { lock.lock(); defer { lock.unlock() }; return n }
    var edges: Int { lock.lock(); defer { lock.unlock() }; return e }
}

final class RebuildTests: XCTestCase {

    // MARK: - Helpers

    private func openStore() throws -> SQLiteStore {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        return store
    }

    private func tempStoreURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftGraphDB-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.sqlite")
    }

    // MARK: - Empty store

    func testEmptyStoreRebuildsToEmptyState() throws {
        let store = try openStore()
        defer { store.close() }

        let result = try RebuildFromSQLite.rebuild(store: store, propertyIndexSpecs: [])
        XCTAssertEqual(result.indexMap.count, 0)
        XCTAssertEqual(result.forward.nodeCount, 0)
        XCTAssertEqual(result.reverse.nodeCount, 0)
        XCTAssertEqual(result.labelIndex.nodes(labeled: "Person"), [])
    }

    // MARK: - Equivalence with incremental construction

    func testRebuildMatchesIncrementalState() throws {
        let store = try openStore()
        defer { store.close() }
        let nodes = NodeRepository(store: store)
        let edges = EdgeRepository(store: store)

        // Seed: 100 Persons, 50 Concepts, edges Person→Concept (random pattern, deterministic).
        let people = (0..<100).map { i in
            Node(label: "Person", properties: ["i": .int(Int64(i))])
        }
        let concepts = (0..<50).map { i in
            Node(label: "Concept", properties: ["i": .int(Int64(i))])
        }
        for n in people { try nodes.insert(n) }
        for n in concepts { try nodes.insert(n) }
        for (i, p) in people.enumerated() {
            try edges.insert(Edge(type: "MENTIONS", fromID: p.id, toID: concepts[i % concepts.count].id))
        }

        let result = try RebuildFromSQLite.rebuild(store: store, propertyIndexSpecs: [])

        XCTAssertEqual(result.indexMap.count, 150)
        XCTAssertEqual(result.labelIndex.nodes(labeled: "Person").count, 100)
        XCTAssertEqual(result.labelIndex.nodes(labeled: "Concept").count, 50)

        // Forward CSR degree for sampled person matches EdgeRepository.fetchOutgoing.
        for sample in people.prefix(5) {
            let i = result.indexMap.internalIndex(for: sample.id)!
            let csrCount = result.forward.degree(of: i)
            let sqlOutgoing = try edges.fetchOutgoing(from: sample.id, type: nil)
            XCTAssertEqual(csrCount, sqlOutgoing.count)
        }

        // Reverse: incoming count for a Concept matches reverse degree.
        let firstConcept = concepts[0]
        let reverseI = result.indexMap.internalIndex(for: firstConcept.id)!
        let reverseCount = result.reverse.degree(of: reverseI)
        let sqlIncoming = try edges.fetchIncoming(to: firstConcept.id, type: nil)
        XCTAssertEqual(reverseCount, sqlIncoming.count)
    }

    // MARK: - Soft-deleted rows are skipped

    func testSoftDeletedRowsAreNotRebuilt() throws {
        let store = try openStore()
        defer { store.close() }
        let nodes = NodeRepository(store: store)
        let alive = Node(label: "Person", properties: ["name": "Alive"])
        let dead = Node(label: "Person", properties: ["name": "Dead"])
        try nodes.insert(alive)
        try nodes.insert(dead)
        try nodes.delete(id: dead.id)

        let result = try RebuildFromSQLite.rebuild(store: store, propertyIndexSpecs: [])
        XCTAssertEqual(result.indexMap.count, 1)
        XCTAssertNotNil(result.indexMap.internalIndex(for: alive.id))
        XCTAssertNil(result.indexMap.internalIndex(for: dead.id))
    }

    // MARK: - Property indexes

    func testDeclaredPropertyIndexIsPopulatedDuringRebuild() throws {
        let store = try openStore()
        defer { store.close() }
        let nodes = NodeRepository(store: store)
        let alice = Node(label: "Person", properties: ["email": "a@example.com"])
        let bob = Node(label: "Person", properties: ["email": "b@example.com"])
        try nodes.insert(alice)
        try nodes.insert(bob)

        let result = try RebuildFromSQLite.rebuild(
            store: store,
            propertyIndexSpecs: [PropertyIndexSpec(label: "Person", property: "email")]
        )
        XCTAssertEqual(
            result.propertyIndex.nodes(label: "Person", property: "email", equals: "a@example.com"),
            [alice.id]
        )
    }

    // MARK: - Progress callback

    func testProgressCallbackInvokedForNonEmptyStore() throws {
        let store = try openStore()
        defer { store.close() }
        let nodes = NodeRepository(store: store)
        for i in 0..<200 {
            try nodes.insert(Node(label: "Person", properties: ["i": .int(Int64(i))]))
        }

        let counter = Counter()
        _ = try RebuildFromSQLite.rebuild(
            store: store,
            propertyIndexSpecs: [],
            progress: .init(reportEvery: 50) { event in
                switch event {
                case .nodes: counter.bumpNodes()
                case .edges: counter.bumpEdges()
                }
            }
        )
        XCTAssertGreaterThan(counter.nodes, 0)
    }

    // MARK: - Persistence + cold rebuild

    func testColdRebuildAcrossReopenMatches() throws {
        let url = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let aliceID: NodeID
        do {
            let store = try SQLiteStore(at: url)
            try MigrationRunner.runDefault(on: store)
            let nodes = NodeRepository(store: store)
            let alice = Node(label: "Person", properties: ["name": "Alice"])
            try nodes.insert(alice)
            aliceID = alice.id
            store.close()
        }

        let store = try SQLiteStore(at: url)
        defer { store.close() }
        try MigrationRunner.runDefault(on: store)
        let result = try RebuildFromSQLite.rebuild(store: store, propertyIndexSpecs: [])
        XCTAssertNotNil(result.indexMap.internalIndex(for: aliceID))
    }

    // MARK: - Performance

    func testRebuildHandles10KNodesUnderPerfBudget() throws {
        let store = try openStore()
        defer { store.close() }
        let importer = BulkImporter(store: store)
        try importer.bulkInsert { batch in
            for i in 0..<10_000 {
                _ = batch.addNode(label: "P", properties: ["i": .int(Int64(i))])
            }
        }

        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            _ = try RebuildFromSQLite.rebuild(store: store, propertyIndexSpecs: [])
        }
        // SPEC §10 cold-launch target is 2s for 100K. 10K should be a small fraction even in
        // debug; we assert a generous 500ms ceiling here.
        XCTAssertLessThan(elapsed, .milliseconds(500), "10K rebuild took \(elapsed)")
    }
}
