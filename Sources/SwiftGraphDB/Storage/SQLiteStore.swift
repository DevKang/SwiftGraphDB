import Foundation
import SQLite3

/// Thin Swift façade over Apple's bundled `SQLite3` C library.
///
/// Decision (SPEC §6.1): the core package depends on Apple's bundled `SQLite3` C library
/// directly rather than a wrapper such as GRDB or `SQLite.swift`. The trade-off is more code
/// here in exchange for zero third-party dependencies in the core target.
///
/// `SQLiteStore` owns a single `sqlite3*` connection and exposes a narrow API: `execute`,
/// `query`, `transaction`, `close`. All higher layers (repositories, the graph actor) call
/// through this façade — `import SQLite3` should not appear anywhere else under
/// `Sources/SwiftGraphDB/` except in this directory.
///
/// Concurrency: `SQLiteStore` is not safe for concurrent calls from multiple tasks. The graph
/// actor (M4) serialises access; tests use the store from a single task.
public final class SQLiteStore: @unchecked Sendable {

    // MARK: - State

    private var db: OpaquePointer?
    private var inTransaction: Bool = false

    // SQLITE_TRANSIENT tells SQLite to copy the buffer; we use it for all binds for safety.
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )

    // MARK: - Lifecycle

    public init(at url: URL, configuration: SQLiteConfiguration = .default) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            handle.map { sqlite3_close_v2($0) }
            throw SQLiteError.open(code: rc, message: message)
        }
        self.db = handle
        try applyConfiguration(configuration, isInMemory: false)
    }

    /// Open an in-memory store. No file is created.
    public static func openInMemory(configuration: SQLiteConfiguration = .default) throws -> SQLiteStore {
        try SQLiteStore(memoryURL: URL(fileURLWithPath: ":memory:"), configuration: configuration)
    }

    private init(memoryURL: URL, configuration: SQLiteConfiguration) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(":memory:", &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            handle.map { sqlite3_close_v2($0) }
            throw SQLiteError.open(code: rc, message: message)
        }
        self.db = handle
        try applyConfiguration(configuration, isInMemory: true)
    }

    /// Apply `SQLiteConfiguration` PRAGMAs immediately after the connection is established and
    /// before any user query runs. SPEC §6.3 requires this ordering.
    ///
    /// `journal_mode = WAL` is unsupported on `:memory:` — the engine reports the request and
    /// silently falls back. We honour that fallback rather than throwing, so an in-memory store
    /// is interchangeable in tests.
    private func applyConfiguration(_ config: SQLiteConfiguration, isInMemory: Bool) throws {
        if config.journalModeWAL && !isInMemory {
            try execute("PRAGMA journal_mode = WAL")
        }
        try execute("PRAGMA synchronous = \(config.synchronous.rawValue)")
        if config.tempStoreInMemory {
            try execute("PRAGMA temp_store = MEMORY")
        }
        try execute("PRAGMA mmap_size = \(config.mmapSize)")
        // Negative cache_size means KB rather than pages.
        try execute("PRAGMA cache_size = \(-config.cacheSizeKB)")
        if !isInMemory {
            try execute("PRAGMA wal_autocheckpoint = \(config.walAutocheckpoint)")
        }
    }

    public func close() {
        guard let db else { return }
        sqlite3_close_v2(db)
        self.db = nil
    }

    deinit { close() }

    // MARK: - Execute (no-result statements)

    /// Run a single SQL statement that returns no rows (`INSERT`, `UPDATE`, `DELETE`,
    /// `CREATE`, etc.). For multi-row results use `query`.
    public func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        let stmt = try prepare(sql: sql, params: params)
        defer { sqlite3_finalize(stmt) }
        try drain(stmt: stmt, rowHandler: nil)
    }

    // MARK: - Query (row-producing statements)

    /// Run a `SELECT` and map each row through `rowHandler`. The handler is called once per
    /// row in a streaming fashion; results are accumulated and returned as an array.
    public func query<T>(
        _ sql: String,
        _ params: [SQLValue] = [],
        _ rowHandler: (Row) throws -> T
    ) throws -> [T] {
        let stmt = try prepare(sql: sql, params: params)
        defer { sqlite3_finalize(stmt) }
        var results: [T] = []
        let row = Row(stmt: stmt)
        while true {
            let rc = sqlite3_step(stmt)
            switch rc {
            case SQLITE_ROW:
                results.append(try rowHandler(row))
            case SQLITE_DONE:
                return results
            default:
                throw SQLiteError.step(code: rc, message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    // MARK: - Transactions

    /// Run `body` inside a `BEGIN` / `COMMIT` pair. Throwing from `body` triggers `ROLLBACK`
    /// and re-throws the original error. Nested transactions are rejected — see SPEC §6.
    @discardableResult
    public func transaction<T>(_ body: (SQLiteStore) throws -> T) throws -> T {
        guard db != nil else { throw SQLiteError.alreadyClosed }
        if inTransaction { throw SQLiteError.nestedTransactionsNotAllowed }

        try execute("BEGIN")
        inTransaction = true
        defer { inTransaction = false }

        do {
            let result = try body(self)
            try execute("COMMIT")
            return result
        } catch {
            // Best-effort rollback — if it fails, surface the original error.
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Internal: prepare / drain

    private func prepare(sql: String, params: [SQLValue]) throws -> OpaquePointer {
        guard let db else { throw SQLiteError.alreadyClosed }
        var stmt: OpaquePointer?
        let prepareRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareRC == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(
                code: prepareRC,
                sql: sql,
                message: String(cString: sqlite3_errmsg(db))
            )
        }
        do {
            try bind(params: params, to: stmt)
        } catch {
            sqlite3_finalize(stmt)
            throw error
        }
        return stmt
    }

    private func drain(stmt: OpaquePointer, rowHandler: ((Row) throws -> Void)?) throws {
        let row = Row(stmt: stmt)
        while true {
            let rc = sqlite3_step(stmt)
            switch rc {
            case SQLITE_ROW:
                if let rowHandler { try rowHandler(row) }
            case SQLITE_DONE:
                return
            default:
                throw SQLiteError.step(
                    code: rc,
                    message: String(cString: sqlite3_errmsg(db))
                )
            }
        }
    }

    private func bind(params: [SQLValue], to stmt: OpaquePointer) throws {
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1) // SQLite parameter indexes are 1-based.
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(stmt, index)
            case .integer(let i):
                rc = sqlite3_bind_int64(stmt, index, i)
            case .real(let d):
                rc = sqlite3_bind_double(stmt, index, d)
            case .text(let s):
                rc = sqlite3_bind_text(stmt, index, s, -1, Self.SQLITE_TRANSIENT)
            case .blob(let data):
                rc = data.withUnsafeBytes { raw -> Int32 in
                    if let base = raw.baseAddress {
                        return sqlite3_bind_blob(stmt, index, base, Int32(raw.count), Self.SQLITE_TRANSIENT)
                    } else {
                        return sqlite3_bind_zeroblob(stmt, index, 0)
                    }
                }
            }
            guard rc == SQLITE_OK else {
                throw SQLiteError.bind(
                    code: rc,
                    message: String(cString: sqlite3_errmsg(db))
                )
            }
        }
    }
}

// MARK: - Row reader

extension SQLiteStore {
    /// Read accessor passed to a query's row handler. Indexes are 0-based.
    public struct Row {
        let stmt: OpaquePointer

        public func isNull(at index: Int) -> Bool {
            sqlite3_column_type(stmt, Int32(index)) == SQLITE_NULL
        }

        public func int(at index: Int) -> Int64? {
            isNull(at: index) ? nil : sqlite3_column_int64(stmt, Int32(index))
        }

        public func double(at index: Int) -> Double? {
            isNull(at: index) ? nil : sqlite3_column_double(stmt, Int32(index))
        }

        public func text(at index: Int) -> String? {
            guard !isNull(at: index), let cString = sqlite3_column_text(stmt, Int32(index)) else {
                return nil
            }
            return String(cString: cString)
        }

        public func blob(at index: Int) -> Data? {
            guard !isNull(at: index) else { return nil }
            let i = Int32(index)
            let count = Int(sqlite3_column_bytes(stmt, i))
            guard count >= 0 else { return Data() }
            if count == 0 { return Data() }
            guard let pointer = sqlite3_column_blob(stmt, i) else { return Data() }
            return Data(bytes: pointer, count: count)
        }
    }
}
