import XCTest
@testable import SwiftGraphDB

final class MigrationTests: XCTestCase {

    // MARK: - Initial migration

    func testFreshOpenStampsCurrentSchemaAndStableGraphID() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }

        try MigrationRunner.runDefault(on: store)

        let version = try meta(store, key: "schema_version")
        XCTAssertEqual(version, "2", "default ships v1 + v2; current head is 2")

        let graphID = try meta(store, key: "graph_id")
        XCTAssertNotNil(graphID)
        XCTAssertNotNil(UUID(uuidString: graphID!))

        // Re-running shouldn't re-stamp graph_id.
        try MigrationRunner.runDefault(on: store)
        XCTAssertEqual(try meta(store, key: "graph_id"), graphID)
    }

    func testReopenDoesNotRerunMigrations() throws {
        let url = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let firstID: String
        do {
            let store = try SQLiteStore(at: url)
            try MigrationRunner.runDefault(on: store)
            firstID = try meta(store, key: "graph_id")!
            store.close()
        }

        let store = try SQLiteStore(at: url)
        defer { store.close() }
        try MigrationRunner.runDefault(on: store)
        XCTAssertEqual(try meta(store, key: "graph_id"), firstID)
        XCTAssertEqual(try meta(store, key: "schema_version"), "2")
    }

    // MARK: - Schema shape

    func testTablesAndIndexesContainBothMigrationLayers() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }
        try MigrationRunner.runDefault(on: store)

        let tables = Set(try store.query("SELECT name FROM sqlite_master WHERE type = 'table'") {
            $0.text(at: 0)!
        })
        // Migration #1 tables + #2 tables.
        XCTAssertTrue(tables.isSuperset(of: [
            "db_meta", "edges", "nodes",
            "change_journal", "sync_checkpoints", "sync_record_versions",
        ]))

        let indexes = Set(try store.query(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'"
        ) { $0.text(at: 0)! })
        XCTAssertTrue(indexes.isSuperset(of: [
            "idx_nodes_label", "idx_edges_from", "idx_edges_to", "idx_edges_type",
            "idx_nodes_revision", "idx_edges_revision",
            "idx_change_journal_entity", "idx_change_journal_sequence", "idx_change_journal_uncompacted",
        ]))
    }

    func testNodesTableColumnsMatchV2Spec() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }
        try MigrationRunner.runDefault(on: store)

        let columns = try store.query("PRAGMA table_info(nodes)") { row in
            row.text(at: 1)!
        }
        XCTAssertEqual(
            Set(columns),
            ["id", "label", "properties", "created_at", "modified_at", "is_deleted", "revision"]
        )
    }

    func testEdgesTableColumnsMatchV2Spec() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }
        try MigrationRunner.runDefault(on: store)

        let columns = try store.query("PRAGMA table_info(edges)") { row in
            row.text(at: 1)!
        }
        XCTAssertEqual(
            Set(columns),
            [
                "id", "type", "from_id", "to_id", "properties",
                "created_at", "modified_at", "is_deleted", "revision",
            ]
        )
    }

    // MARK: - Migration registry semantics

    func testMigrationFailureRollsBack() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }

        let runner = MigrationRunner(migrations: [
            Migration(version: 1, sql: "CREATE TABLE foo (id INTEGER PRIMARY KEY);"),
            Migration(version: 2, sql: "CREATE TABLE bar (id INTEGER PRIMARY KEY); CREATE NONSENSE;"),
        ])

        XCTAssertThrowsError(try runner.run(on: store))

        let version = try meta(store, key: "schema_version")
        XCTAssertEqual(version, "1")

        let tables = try store.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") {
            $0.text(at: 0)!
        }
        XCTAssertTrue(tables.contains("foo"))
        XCTAssertFalse(tables.contains("bar"), "failed migration should not have left tables behind")
    }

    func testHypotheticalMigration3RunsOnceOnNextOpen() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }

        try MigrationRunner.runDefault(on: store)

        let extended = MigrationRunner(migrations: MigrationRunner.defaultMigrations + [
            Migration(version: 3, sql: "CREATE TABLE extension_table (id INTEGER PRIMARY KEY)"),
        ])
        try extended.run(on: store)
        XCTAssertEqual(try meta(store, key: "schema_version"), "3")

        // Running again is a no-op.
        try extended.run(on: store)
        let count = try store.query("SELECT COUNT(*) FROM extension_table") { $0.int(at: 0)! }.first ?? -1
        XCTAssertEqual(count, 0)
    }

    // MARK: - Helpers

    private func meta(_ store: SQLiteStore, key: String) throws -> String? {
        try store.query("SELECT value FROM db_meta WHERE key = ?", [.text(key)]) { $0.text(at: 0) }
            .first
            .flatMap { $0 }
    }

    private func tempStoreURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftGraphDB-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.sqlite")
    }
}
