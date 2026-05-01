import Foundation

/// A value that can be bound to a SQLite statement parameter or read from a result row.
///
/// This is the bridge type between Swift code and SQLite's five-type model
/// (`NULL`, `INTEGER`, `REAL`, `TEXT`, `BLOB`). `PropertyValue` is *not* used here — properties
/// are encoded to JSON BLOBs by upstream layers.
public enum SQLValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}
