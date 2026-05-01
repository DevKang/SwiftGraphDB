import XCTest
@testable import SwiftGraphDB

final class SQLiteStoreTests: XCTestCase {

    // MARK: - In-memory open + basic CRUD

    func testInMemoryStoreCreateInsertSelect() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }

        try store.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        try store.execute("INSERT INTO t (id, name) VALUES (?, ?)", [.integer(1), .text("alice")])

        let rows = try store.query("SELECT id, name FROM t") { row in
            (row.int(at: 0)!, row.text(at: 1)!)
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].0, 1)
        XCTAssertEqual(rows[0].1, "alice")
    }

    // MARK: - Persistence across close/reopen

    func testTempFileStorePersistsAcrossReopen() throws {
        let url = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let store = try SQLiteStore(at: url)
            try store.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, payload BLOB)")
            try store.execute(
                "INSERT INTO t (id, payload) VALUES (?, ?)",
                [.integer(7), .blob(Data([0x01, 0x02, 0x03]))]
            )
            store.close()
        }

        let store = try SQLiteStore(at: url)
        defer { store.close() }
        let payload = try store.query("SELECT payload FROM t WHERE id = ?", [.integer(7)]) { row in
            row.blob(at: 0)!
        }.first
        XCTAssertEqual(payload, Data([0x01, 0x02, 0x03]))
    }

    // MARK: - Transactions

    func testTransactionRollsBackOnThrow() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }
        try store.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")

        struct Boom: Error {}
        XCTAssertThrowsError(
            try store.transaction { _ in
                try store.execute("INSERT INTO t (id) VALUES (?)", [.integer(1)])
                try store.execute("INSERT INTO t (id) VALUES (?)", [.integer(2)])
                throw Boom()
            }
        )

        let count = try store.query("SELECT COUNT(*) FROM t") { row in row.int(at: 0)! }.first ?? -1
        XCTAssertEqual(count, 0, "transaction should have rolled back")
    }

    func testTransactionCommitsOnSuccess() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }
        try store.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")

        try store.transaction { _ in
            try store.execute("INSERT INTO t (id) VALUES (?)", [.integer(1)])
            try store.execute("INSERT INTO t (id) VALUES (?)", [.integer(2)])
        }

        let count = try store.query("SELECT COUNT(*) FROM t") { row in row.int(at: 0)! }.first ?? -1
        XCTAssertEqual(count, 2)
    }

    func testNestedTransactionIsRejected() throws {
        // Documented policy: nested transactions are rejected (no savepoints in the public API yet).
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }

        XCTAssertThrowsError(
            try store.transaction { _ in
                try store.transaction { _ in }
            }
        ) { error in
            guard case SQLiteError.nestedTransactionsNotAllowed = error else {
                return XCTFail("expected .nestedTransactionsNotAllowed, got \(error)")
            }
        }
    }

    // MARK: - Typed errors

    func testInvalidSQLSurfacesTypedError() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }

        XCTAssertThrowsError(try store.execute("SELECT * FROM nope_no_such_table")) { error in
            guard case SQLiteError.prepare(let code, _, let message) = error else {
                return XCTFail("expected .prepare error, got \(error)")
            }
            XCTAssertNotEqual(code, 0)
            XCTAssertFalse(message.isEmpty)
        }
    }

    // MARK: - Helpers

    private func tempStoreURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftGraphDB-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.sqlite")
    }
}
