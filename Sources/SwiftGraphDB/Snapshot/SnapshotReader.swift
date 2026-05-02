import Foundation

/// Validated snapshot reader. Surfaces typed errors per SPEC §6.4 — anything off → caller
/// rebuilds from SQLite (no data loss because SQLite is the source of truth).
public enum SnapshotReader {
    /// Read + validate the snapshot at `url`. Verifies:
    /// - file exists and matches the expected magic/format
    /// - CRC32 of the body
    /// - the embedded `schemaVersion` matches `expectedSchemaVersion`
    public static func read(at url: URL, expectedSchemaVersion: Int32) throws -> SnapshotPayload {
        let data = try Data(contentsOf: url)
        let payload = try SnapshotFormat.decode(data)
        guard payload.schemaVersion == expectedSchemaVersion else {
            throw SnapshotError.schemaVersionMismatch(
                found: payload.schemaVersion,
                expected: expectedSchemaVersion
            )
        }
        return payload
    }
}
