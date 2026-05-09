import Foundation

/// One ordered schema-evolution step.
///
/// Migrations are append-only: never edit a previously released migration's `sql`. Add a new one
/// with a higher version number instead. The runner stamps `db_meta.schema_version` only after
/// the migration's transaction commits, so a partially-applied migration cannot leave the
/// database half-evolved.
public struct Migration: Sendable {
    public let version: Int
    /// Runs inside the migration runner's transaction. May execute SQL, stamp `db_meta`, or
    /// perform per-row backfill — whatever the version requires.
    public let perform: @Sendable (SQLiteStore) throws -> Void

    public init(version: Int, perform: @escaping @Sendable (SQLiteStore) throws -> Void) {
        self.version = version
        self.perform = perform
    }

    /// Convenience for SQL-only migrations. Executes each `;`-delimited statement in order.
    public init(version: Int, sql: String) {
        self.version = version
        self.perform = { store in
            let statements = sql.split(separator: ";").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            for stmt in statements {
                try store.execute(stmt)
            }
        }
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
        v1,
        v2,
        v3,
    ]

    private static let v1 = Migration(version: 1, sql: """
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

    /// Migration #2 — schema v2 (SPEC §5.1). Adds `revision` columns, the append-only
    /// change journal, and per-backend sync metadata tables. Stamps a fresh `actor_id` and
    /// back-fills existing v1 rows with `(actor_id, 0, modified_at)` so revisions are
    /// immediately consistent with the v2 model.
    private static let v2 = Migration(version: 2) { store in
        // 1. ALTER TABLE node/edge — add nullable revision; we backfill before any code reads.
        try store.execute("ALTER TABLE nodes ADD COLUMN revision TEXT")
        try store.execute("ALTER TABLE edges ADD COLUMN revision TEXT")
        try store.execute("CREATE INDEX idx_nodes_revision ON nodes(revision)")
        try store.execute("CREATE INDEX idx_edges_revision ON edges(revision)")

        // 2. Stamp actor_id once per store.
        let existing = try store.query(
            "SELECT value FROM db_meta WHERE key = ?", [.text("actor_id")]
        ) { $0.text(at: 0) }
        let actorIDString: String
        if let value = existing.first.flatMap({ $0 }) {
            actorIDString = value
        } else {
            actorIDString = UUID().uuidString
            try store.execute(
                "INSERT INTO db_meta (key, value) VALUES (?, ?)",
                [.text("actor_id"), .text(actorIDString)]
            )
        }

        // 3. Backfill `revision` for existing nodes and edges.
        let actor = ActorID(uuidString: actorIDString)!
        try MigrationRunner.backfillRevision(table: "nodes", store: store, actor: actor)
        try MigrationRunner.backfillRevision(table: "edges", store: store, actor: actor)

        // 4. Create the change journal + sync metadata tables.
        try store.execute("""
        CREATE TABLE change_journal (
            sequence       INTEGER PRIMARY KEY AUTOINCREMENT,
            change_id      TEXT NOT NULL UNIQUE,
            graph_id       TEXT NOT NULL,
            actor_id       TEXT NOT NULL,
            entity_kind    TEXT NOT NULL CHECK (entity_kind IN ('node', 'edge')),
            entity_id      TEXT NOT NULL,
            operation      TEXT NOT NULL CHECK (operation IN ('upsert', 'delete')),
            payload        BLOB,
            base_revision  TEXT,
            revision       TEXT NOT NULL,
            created_at     REAL NOT NULL,
            compacted_at   REAL
        )
        """)
        try store.execute("CREATE INDEX idx_change_journal_entity ON change_journal(entity_kind, entity_id)")
        try store.execute("CREATE INDEX idx_change_journal_sequence ON change_journal(sequence)")
        try store.execute("""
        CREATE INDEX idx_change_journal_uncompacted ON change_journal(sequence)
        WHERE compacted_at IS NULL
        """)

        try store.execute("""
        CREATE TABLE sync_checkpoints (
            backend_id      TEXT PRIMARY KEY,
            checkpoint      BLOB,
            high_watermark  INTEGER NOT NULL DEFAULT 0,
            updated_at      REAL NOT NULL
        )
        """)

        try store.execute("""
        CREATE TABLE sync_record_versions (
            backend_id            TEXT NOT NULL,
            entity_kind           TEXT NOT NULL CHECK (entity_kind IN ('node', 'edge')),
            entity_id             TEXT NOT NULL,
            last_synced_revision  TEXT NOT NULL,
            base_payload          BLOB,
            updated_at            REAL NOT NULL,
            PRIMARY KEY (backend_id, entity_kind, entity_id)
        )
        """)
    }

    /// Migration #3 — schema v3. Converts `properties` from BLOB to TEXT so that
    /// `json_extract()` can be used for SQLite-native filtering, sorting, and pagination.
    /// The existing BLOBs are valid UTF-8 JSON produced by `JSONEncoder`, so `CAST(... AS TEXT)`
    /// is safe. Tables are rebuilt because SQLite does not support `ALTER COLUMN`.
    private static let v3 = Migration(version: 3) { store in
        // -- nodes --
        try store.execute("""
        CREATE TABLE nodes_v3 (
            id          TEXT PRIMARY KEY,
            label       TEXT NOT NULL,
            properties  TEXT NOT NULL,
            created_at  REAL NOT NULL,
            modified_at REAL NOT NULL,
            is_deleted  INTEGER NOT NULL DEFAULT 0,
            revision    TEXT
        )
        """)
        try store.execute("""
        INSERT INTO nodes_v3 (id, label, properties, created_at, modified_at, is_deleted, revision)
        SELECT id, label, CAST(properties AS TEXT), created_at, modified_at, is_deleted, revision
        FROM nodes
        """)
        try store.execute("DROP TABLE nodes")
        try store.execute("ALTER TABLE nodes_v3 RENAME TO nodes")
        try store.execute("CREATE INDEX idx_nodes_label ON nodes(label) WHERE is_deleted = 0")
        try store.execute("CREATE INDEX idx_nodes_revision ON nodes(revision)")

        // -- edges --
        try store.execute("""
        CREATE TABLE edges_v3 (
            id          TEXT PRIMARY KEY,
            type        TEXT NOT NULL,
            from_id     TEXT NOT NULL REFERENCES nodes(id),
            to_id       TEXT NOT NULL REFERENCES nodes(id),
            properties  TEXT NOT NULL,
            created_at  REAL NOT NULL,
            modified_at REAL NOT NULL,
            is_deleted  INTEGER NOT NULL DEFAULT 0,
            revision    TEXT
        )
        """)
        try store.execute("""
        INSERT INTO edges_v3 (id, type, from_id, to_id, properties, created_at, modified_at, is_deleted, revision)
        SELECT id, type, from_id, to_id, CAST(properties AS TEXT), created_at, modified_at, is_deleted, revision
        FROM edges
        """)
        try store.execute("DROP TABLE edges")
        try store.execute("ALTER TABLE edges_v3 RENAME TO edges")
        try store.execute("CREATE INDEX idx_edges_from ON edges(from_id) WHERE is_deleted = 0")
        try store.execute("CREATE INDEX idx_edges_to ON edges(to_id) WHERE is_deleted = 0")
        try store.execute("CREATE INDEX idx_edges_type ON edges(type) WHERE is_deleted = 0")
        try store.execute("CREATE INDEX idx_edges_revision ON edges(revision)")
    }

    /// Backfill helper for migration #2.
    fileprivate static func backfillRevision(table: String, store: SQLiteStore, actor: ActorID) throws {
        struct Row { let id: String; let modifiedAt: Double }
        let rows = try store.query(
            "SELECT id, modified_at FROM \(table) WHERE revision IS NULL"
        ) { row in
            Row(id: row.text(at: 0) ?? "", modifiedAt: row.double(at: 1) ?? 0)
        }
        let encoder = JSONEncoder()
        for r in rows {
            let revision = GraphRevision(
                actorID: actor,
                counter: 0,
                wallClock: Date(timeIntervalSince1970: r.modifiedAt)
            )
            let json = String(data: try encoder.encode(revision), encoding: .utf8) ?? "{}"
            try store.execute(
                "UPDATE \(table) SET revision = ? WHERE id = ?",
                [.text(json), .text(r.id)]
            )
        }
    }

    /// Convenience: open-on-first-use migration runner with the default schema.
    public static func runDefault(on store: SQLiteStore) throws {
        try MigrationRunner(migrations: defaultMigrations).run(on: store)
    }

    public func run(on store: SQLiteStore) throws {
        try ensureMetaTable(store)
        let current = try currentVersion(store)

        for migration in migrations where migration.version > current {
            try store.transaction { _ in
                try migration.perform(store)
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

}
