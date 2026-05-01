import Foundation

/// Typed errors surfaced by the SQLite façade. SQLite's C-level result codes are exposed as
/// `code`; the underlying `sqlite3*` pointer never leaks across this boundary.
public enum SQLiteError: Error, Equatable {
    /// `sqlite3_open_v2` failed.
    case open(code: Int32, message: String)
    /// `sqlite3_prepare_v2` failed (typically a syntax error or missing object).
    case prepare(code: Int32, sql: String, message: String)
    /// `sqlite3_bind_*` failed.
    case bind(code: Int32, message: String)
    /// `sqlite3_step` returned an error code other than `SQLITE_DONE` or `SQLITE_ROW`.
    case step(code: Int32, message: String)
    /// The store is closed and no further operations are accepted.
    case alreadyClosed
    /// `transaction` was called from inside another `transaction` body.
    /// The current public API does not support savepoints; restructure the caller.
    case nestedTransactionsNotAllowed
}
