import XCTest
@testable import SwiftGraphDB

final class RepositoryRevisionTests: XCTestCase {

    private let testActor = ActorID()
    private var counter: Int64 = 0

    private func nextRev() -> GraphRevision {
        counter += 1
        return GraphRevision(actorID: testActor, counter: counter, wallClock: Date())
    }

    private func openStore() throws -> SQLiteStore {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        return store
    }

    // MARK: - Insert + fetch round-trips revision

    func testNodeInsertRoundTripsRevision() throws {
        let store = try openStore()
        defer { store.close() }
        let revision = nextRev()
        let node = Node(label: "Person", properties: ["name": "Alice"], revision: revision)
        let repo = NodeRepository(store: store)
        try repo.insert(node)
        let fetched = try repo.fetch(id: node.id)
        XCTAssertEqual(fetched?.revision, revision)
    }

    func testEdgeInsertRoundTripsRevision() throws {
        let store = try openStore()
        defer { store.close() }
        let nodes = NodeRepository(store: store)
        let edges = EdgeRepository(store: store)
        let a = Node(label: "Person", revision: nextRev()); try nodes.insert(a)
        let b = Node(label: "Person", revision: nextRev()); try nodes.insert(b)
        let revision = nextRev()
        let edge = Edge(type: "KNOWS", fromID: a.id, toID: b.id, revision: revision)
        try edges.insert(edge)
        XCTAssertEqual(try edges.fetch(id: edge.id)?.revision, revision)
    }

    // MARK: - Update bumps revision and refuses placeholder

    func testUpdateNodeStampsNewRevision() throws {
        let store = try openStore()
        defer { store.close() }
        let repo = NodeRepository(store: store)
        let original = nextRev()
        try repo.insert(Node(label: "Person", revision: original))
        let id = (try repo.fetchAll(label: "Person").first!).id

        let bumped = nextRev()
        try repo.update(id: id, properties: ["x": 1], revision: bumped)
        XCTAssertEqual(try repo.fetch(id: id)?.revision, bumped)
        XCTAssertNotEqual(try repo.fetch(id: id)?.revision, original)
    }

    func testUpdateRefusesPlaceholderRevision() throws {
        let store = try openStore()
        defer { store.close() }
        let repo = NodeRepository(store: store)
        let n = Node(label: "Person", revision: nextRev())
        try repo.insert(n)
        XCTAssertThrowsError(try repo.update(id: n.id, properties: [:], revision: GraphRevision.placeholder())) { err in
            guard case RepositoryError.placeholderRevision = err else {
                return XCTFail("expected placeholderRevision, got \(err)")
            }
        }
    }

    // MARK: - Delete carries revision into Tombstone

    func testNodeTombstoneCarriesRevision() throws {
        let store = try openStore()
        defer { store.close() }
        let repo = NodeRepository(store: store)
        let n = Node(label: "Person", revision: nextRev())
        try repo.insert(n)
        let deleteRev = nextRev()
        try repo.delete(id: n.id, revision: deleteRev)

        let tombstones = TombstoneStore(store: store)
        let dead = try tombstones.nodeTombstones(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(dead.count, 1)
        XCTAssertEqual(dead.first?.revision, deleteRev)
    }

    func testEdgeTombstoneCarriesRevision() throws {
        let store = try openStore()
        defer { store.close() }
        let nodes = NodeRepository(store: store)
        let edges = EdgeRepository(store: store)
        let a = Node(label: "Person", revision: nextRev()); try nodes.insert(a)
        let b = Node(label: "Person", revision: nextRev()); try nodes.insert(b)
        let edge = Edge(type: "KNOWS", fromID: a.id, toID: b.id, revision: nextRev())
        try edges.insert(edge)

        let deleteRev = nextRev()
        try edges.delete(id: edge.id, revision: deleteRev)

        let tombstones = TombstoneStore(store: store)
        let dead = try tombstones.edgeTombstones(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(dead.first?.revision, deleteRev)
    }

    // MARK: - V1 backfill

    func testV1BackfilledRowDecodesRevisionFromMigration() throws {
        // Build a v1 store, seed a row, then upgrade. Verify the fetched node's revision
        // matches the backfilled row.
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }
        try MigrationRunner(migrations: [MigrationRunner.defaultMigrations[0]]).run(on: store)

        let id = UUID().uuidString
        try store.execute("""
        INSERT INTO nodes (id, label, properties, created_at, modified_at, is_deleted)
        VALUES (?, 'Person', x'7b7d', 1700000000.0, 1700000050.0, 0)
        """, [.text(id)])

        try MigrationRunner.runDefault(on: store) // migration #2 backfills

        let repo = NodeRepository(store: store)
        let node = try repo.fetch(id: UUID(uuidString: id)!)!
        XCTAssertEqual(node.revision.counter, 0)
        XCTAssertEqual(node.revision.wallClock.timeIntervalSince1970, 1700000050.0, accuracy: 0.001)
    }
}
