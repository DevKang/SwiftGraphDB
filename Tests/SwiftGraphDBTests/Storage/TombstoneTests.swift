import XCTest
@testable import SwiftGraphDB

final class TombstoneTests: XCTestCase {

    // MARK: - Soft delete keeps the row

    func testSoftDeleteLeavesRowInTable() throws {
        let (store, repo) = try makeNodeRepo()
        defer { store.close() }
        let n = Node(label: "Person", properties: ["name": "Alice"])
        try repo.insert(n)

        try repo.delete(id: n.id)

        // Row count is unchanged — only is_deleted flipped.
        let count = try store.query("SELECT COUNT(*) FROM nodes") { $0.int(at: 0)! }.first
        XCTAssertEqual(count, 1)

        let raw = try store.query(
            "SELECT is_deleted FROM nodes WHERE id = ?",
            [.text(n.id.uuidString)]
        ) { $0.int(at: 0)! }.first
        XCTAssertEqual(raw, 1)
    }

    // MARK: - fetchTombstones(since:)

    func testFetchNodeTombstonesSinceCutoff() throws {
        let (store, repo) = try makeNodeRepo()
        let tombstones = TombstoneStore(store: store)
        defer { store.close() }

        let alive = Node(label: "Person", properties: ["name": "Alive"])
        let dead = Node(label: "Person", properties: ["name": "Dead"])
        try repo.insert(alive)
        try repo.insert(dead)

        let cutoff = Date(timeIntervalSinceNow: -1) // include all from now back 1s
        try repo.delete(id: dead.id)

        let dueAfterCutoff = try tombstones.nodeTombstones(since: cutoff)
        XCTAssertEqual(dueAfterCutoff.map(\.id), [dead.id])

        let future = Date(timeIntervalSinceNow: 60)
        let dueAfterFuture = try tombstones.nodeTombstones(since: future)
        XCTAssertTrue(dueAfterFuture.isEmpty)
    }

    func testFetchEdgeTombstonesSinceCutoff() throws {
        let (store, nodes, edges) = try makeBothRepos()
        let tombstones = TombstoneStore(store: store)
        defer { store.close() }

        let a = Node(label: "Person"); try nodes.insert(a)
        let b = Node(label: "Person"); try nodes.insert(b)
        let edge = Edge(type: "KNOWS", fromID: a.id, toID: b.id)
        try edges.insert(edge)

        let cutoff = Date(timeIntervalSinceNow: -1)
        try edges.delete(id: edge.id)

        let dead = try tombstones.edgeTombstones(since: cutoff)
        XCTAssertEqual(dead.map(\.id), [edge.id])
    }

    // MARK: - Resurrection rejected

    func testReinsertingDeletedIDIsRejected() throws {
        // Decision: resurrection of a previously-deleted id is rejected at the storage layer.
        // See `// TODO(M8):` — sync may need to revisit this.
        let (store, repo) = try makeNodeRepo()
        defer { store.close() }
        let id = IDFactory.live.nodeID()
        try repo.insert(Node(id: id, label: "Person"))
        try repo.delete(id: id)

        XCTAssertThrowsError(try repo.insert(Node(id: id, label: "Person")))
    }

    // MARK: - Rebuild contract

    func testTombstonesSurviveCloseAndReopen() throws {
        let url = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let id: NodeID
        do {
            let store = try SQLiteStore(at: url)
            try MigrationRunner.runDefault(on: store)
            let repo = NodeRepository(store: store)
            let n = Node(label: "Person")
            try repo.insert(n)
            id = n.id
            try repo.delete(id: id)
            store.close()
        }

        let store = try SQLiteStore(at: url)
        defer { store.close() }
        try MigrationRunner.runDefault(on: store)

        let repo = NodeRepository(store: store)
        XCTAssertNil(try repo.fetch(id: id), "deleted row stays deleted across reopen")

        let tombstones = TombstoneStore(store: store)
        let earliest = Date(timeIntervalSince1970: 0)
        let dead = try tombstones.nodeTombstones(since: earliest)
        XCTAssertEqual(dead.map(\.id), [id])
    }

    // MARK: - Helpers

    private func makeNodeRepo() throws -> (SQLiteStore, NodeRepository) {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        return (store, NodeRepository(store: store))
    }

    private func makeBothRepos() throws -> (SQLiteStore, NodeRepository, EdgeRepository) {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        return (store, NodeRepository(store: store), EdgeRepository(store: store))
    }

    private func tempStoreURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftGraphDB-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.sqlite")
    }
}
