import XCTest
@testable import SwiftGraphDB

final class MigrationV2Tests: XCTestCase {

    // MARK: - Helpers

    private func openFresh() throws -> SQLiteStore {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        return store
    }

    private func tableExists(_ store: SQLiteStore, _ name: String) throws -> Bool {
        let rows = try store.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            [.text(name)]
        ) { $0.text(at: 0) }
        return !rows.isEmpty
    }

    private func columnNames(_ store: SQLiteStore, table: String) throws -> [String] {
        try store.query("PRAGMA table_info(\(table))") { $0.text(at: 1) ?? "" }
    }

    private func meta(_ store: SQLiteStore, key: String) throws -> String? {
        try store.query("SELECT value FROM db_meta WHERE key = ?", [.text(key)]) { $0.text(at: 0) }
            .first.flatMap { $0 }
    }

    // MARK: - Fresh open at v2

    func testFreshOpenStampsSchemaVersion2() throws {
        let store = try openFresh()
        defer { store.close() }
        XCTAssertEqual(try meta(store, key: "schema_version"), "2")
    }

    func testFreshOpenStampsActorIDOncePerStore() throws {
        let store = try openFresh()
        defer { store.close() }
        let firstActor = try meta(store, key: "actor_id")
        XCTAssertNotNil(firstActor)
        XCTAssertNotNil(UUID(uuidString: firstActor!))

        // Re-running the migrations is idempotent.
        try MigrationRunner.runDefault(on: store)
        XCTAssertEqual(try meta(store, key: "actor_id"), firstActor)
    }

    func testActorIDDiffersFromGraphID() throws {
        let store = try openFresh()
        defer { store.close() }
        XCTAssertNotEqual(try meta(store, key: "graph_id"),
                          try meta(store, key: "actor_id"))
    }

    // MARK: - Schema shape

    func testNodesTableHasRevisionColumn() throws {
        let store = try openFresh()
        defer { store.close() }
        XCTAssertTrue(try columnNames(store, table: "nodes").contains("revision"))
    }

    func testEdgesTableHasRevisionColumn() throws {
        let store = try openFresh()
        defer { store.close() }
        XCTAssertTrue(try columnNames(store, table: "edges").contains("revision"))
    }

    func testNewTablesPresent() throws {
        let store = try openFresh()
        defer { store.close() }
        XCTAssertTrue(try tableExists(store, "change_journal"))
        XCTAssertTrue(try tableExists(store, "sync_checkpoints"))
        XCTAssertTrue(try tableExists(store, "sync_record_versions"))
    }

    func testChangeJournalRequiredColumns() throws {
        let store = try openFresh()
        defer { store.close() }
        let cols = Set(try columnNames(store, table: "change_journal"))
        let expected: Set<String> = [
            "sequence", "change_id", "graph_id", "actor_id",
            "entity_kind", "entity_id", "operation", "payload",
            "base_revision", "revision", "created_at", "compacted_at"
        ]
        XCTAssertTrue(expected.isSubset(of: cols))
    }

    func testChangeJournalRejectsInvalidEntityKind() throws {
        let store = try openFresh()
        defer { store.close() }
        let revisionJSON = "{\"actorID\":\"\(UUID().uuidString)\",\"counter\":1,\"wallClock\":1.0}"
        XCTAssertThrowsError(try store.execute(
            """
            INSERT INTO change_journal
            (change_id, graph_id, actor_id, entity_kind, entity_id, operation, revision, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(UUID().uuidString),
                .text(UUID().uuidString),
                .text(UUID().uuidString),
                .text("nope"), // CHECK violation
                .text(UUID().uuidString),
                .text("upsert"),
                .text(revisionJSON),
                .real(0),
            ]
        ))
    }

    // MARK: - Backfill of v1 data

    func testV1DataIsBackfilledOnUpgrade() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }
        // Run only migration #1 to simulate a v1 store.
        let v1Only = MigrationRunner(migrations: [MigrationRunner.defaultMigrations[0]])
        try v1Only.run(on: store)
        XCTAssertEqual(try meta(store, key: "schema_version"), "1")

        // Seed v1-shaped rows directly (no revision column yet).
        let id = UUID().uuidString
        try store.execute(
            """
            INSERT INTO nodes (id, label, properties, created_at, modified_at, is_deleted)
            VALUES (?, 'Person', x'7b7d', 1700000000.0, 1700000050.0, 0)
            """,
            [.text(id)]
        )

        // Now run all migrations; v1 → v2 backfill must populate revision for existing rows.
        try MigrationRunner.runDefault(on: store)
        XCTAssertEqual(try meta(store, key: "schema_version"), "2")

        let revisions = try store.query(
            "SELECT revision FROM nodes WHERE id = ?", [.text(id)]
        ) { $0.text(at: 0) }.compactMap { $0 }
        XCTAssertEqual(revisions.count, 1)
        XCTAssertFalse(revisions[0].isEmpty, "backfilled revision must not be empty")

        // Decode the backfilled JSON and verify the actor matches db_meta.actor_id.
        let actorID = try meta(store, key: "actor_id")!
        let revData = revisions[0].data(using: .utf8)!
        let revision = try JSONDecoder().decode(GraphRevision.self, from: revData)
        XCTAssertEqual(revision.actorID.uuidString, actorID)
        XCTAssertEqual(revision.counter, 0)
    }

    // MARK: - Failure rolls back

    func testFailingMigrationLeavesPriorVersion() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }
        try MigrationRunner(migrations: [MigrationRunner.defaultMigrations[0]]).run(on: store)
        XCTAssertEqual(try meta(store, key: "schema_version"), "1")

        let runner = MigrationRunner(migrations: MigrationRunner.defaultMigrations + [
            Migration(version: 3, sql: "CREATE NONSENSE syntax error"),
        ])
        XCTAssertThrowsError(try runner.run(on: store))

        // Migration #2 is committed (it succeeded), but #3 rolled back.
        XCTAssertEqual(try meta(store, key: "schema_version"), "2")
    }
}
