import Foundation

/// One ordered schema-evolution step.
///
/// Migrations are append-only: never edit a previously released migration's `sql`. Add a new one
/// with a higher version number instead. The runner stamps `db_meta.schema_version` only after
/// the migration's transaction commits, so a partially-applied migration cannot leave the
/// database half-evolved.
public struct Migration: Sendable {
    public let version: Int
    public let sql: String
    public init(version: Int, sql: String) {
        self.version = version
        self.sql = sql
    }
}

/// Applies an ordered list of `Migration`s to a `SQLiteStore`.
public struct MigrationRunner: Sendable {

    public let migrations: [Migration]

    public init(migrations: [Migration]) {
        // Defensive: callers should hand in a sorted list, but enforce it anyway.
        self.migrations = migrations.sorted { $0.version < $1.version }
    }

    /// The migrations that ship with `SwiftGraphDB`. New schema work appends to this list.
    public static let defaultMigrations: [Migration] = [
        Migration(version: 1, sql: """
        CREATE TABLE nodes (
            id          TEXT PRIMARY KEY,
            label       TEXT NOT NULL,
            properties  BLOB NOT NULL,
            created_at  REAL NOT NULL,
            modified_at REAL NOT NULL,
            is_deleted  INTEGER NOT NULL DEFAULT 0
        );

        CREATE INDEX idx_nodes_label
        ON nodes(label)
        WHERE is_deleted = 0;

        CREATE TABLE edges (
            id          TEXT PRIMARY KEY,
            type        TEXT NOT NULL,
            from_id     TEXT NOT NULL REFERENCES nodes(id),
            to_id       TEXT NOT NULL REFERENCES nodes(id),
            properties  BLOB NOT NULL,
            created_at  REAL NOT NULL,
            modified_at REAL NOT NULL,
            is_deleted  INTEGER NOT NULL DEFAULT 0
        );

        CREATE INDEX idx_edges_from
        ON edges(from_id)
        WHERE is_deleted = 0;

        CREATE INDEX idx_edges_to
        ON edges(to_id)
        WHERE is_deleted = 0;

        CREATE INDEX idx_edges_type
        ON edges(type)
        WHERE is_deleted = 0;
        """)
        // Note: `db_meta` is bootstrapped by MigrationRunner before any migration runs,
        // because we need it to record `schema_version` for the very first migration. It is
        // therefore not part of migration #1's CREATE statements.
    ]

    /// Convenience: open-on-first-use migration runner with the default schema.
    public static func runDefault(on store: SQLiteStore) throws {
        try MigrationRunner(migrations: defaultMigrations).run(on: store)
    }

    public func run(on store: SQLiteStore) throws {
        try ensureMetaTable(store)
        let current = try currentVersion(store)

        for migration in migrations where migration.version > current {
            try store.transaction { _ in
                try executeAll(sql: migration.sql, on: store)
                try setVersion(migration.version, on: store)
            }
        }

        // Stamp graph_id once per database (it is the durable identity of the file).
        try ensureGraphID(store)
    }

    // MARK: - Internals

    private func ensureMetaTable(_ store: SQLiteStore) throws {
        // db_meta might not exist yet (very first migration creates it). Use IF NOT EXISTS so
        // re-runs after migration #1 stay idempotent.
        try store.execute("""
        CREATE TABLE IF NOT EXISTS db_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
    }

    private func currentVersion(_ store: SQLiteStore) throws -> Int {
        let rows = try store.query(
            "SELECT value FROM db_meta WHERE key = ?",
            [.text("schema_version")]
        ) { $0.text(at: 0) }
        return rows.first.flatMap { $0 }.flatMap(Int.init) ?? 0
    }

    private func setVersion(_ version: Int, on store: SQLiteStore) throws {
        try store.execute(
            """
            INSERT INTO db_meta (key, value) VALUES ('schema_version', ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            [.text(String(version))]
        )
    }

    private func ensureGraphID(_ store: SQLiteStore) throws {
        let existing = try store.query(
            "SELECT value FROM db_meta WHERE key = ?",
            [.text("graph_id")]
        ) { $0.text(at: 0) }
        if existing.isEmpty {
            try store.execute(
                "INSERT INTO db_meta (key, value) VALUES (?, ?)",
                [.text("graph_id"), .text(UUID().uuidString)]
            )
        }
    }

    private func executeAll(sql: String, on store: SQLiteStore) throws {
        // SQLite's prepare_v2 only handles one statement per call. Split on `;` boundaries
        // (naïve but sufficient: our migration SQL never embeds a semicolon inside a string).
        let statements = sql.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        for stmt in statements {
            try store.execute(stmt)
        }
    }
}
