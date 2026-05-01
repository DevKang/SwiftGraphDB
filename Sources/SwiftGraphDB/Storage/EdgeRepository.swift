import Foundation

/// CRUD operations on the `edges` SQLite table. Soft-delete by default; tombstone semantics
/// (rebuild contract) live in `Tombstones.swift`.
public struct EdgeRepository: Sendable {

    public let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    // MARK: - Insert

    /// Insert an edge. Throws `RepositoryError.endpointMissing` if either endpoint does not
    /// reference an existing live node — SQLite's `REFERENCES` enforces it via the FK constraint
    /// once enabled, but the repo also pre-checks so the error type is meaningful.
    public func insert(_ edge: Edge) throws {
        try ensureNodeExists(id: edge.fromID)
        try ensureNodeExists(id: edge.toID)
        let blob = try PropertyCoding.encode(edge.properties)
        try store.execute(
            """
            INSERT INTO edges (id, type, from_id, to_id, properties, created_at, modified_at, is_deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0)
            """,
            [
                .text(edge.id.uuidString),
                .text(edge.type),
                .text(edge.fromID.uuidString),
                .text(edge.toID.uuidString),
                .blob(blob),
                .real(edge.createdAt.timeIntervalSince1970),
                .real(edge.modifiedAt.timeIntervalSince1970),
            ]
        )
    }

    // MARK: - Fetch

    public func fetch(id: EdgeID) throws -> Edge? {
        try store.query(
            """
            SELECT id, type, from_id, to_id, properties, created_at, modified_at
            FROM edges
            WHERE id = ? AND is_deleted = 0
            """,
            [.text(id.uuidString)]
        ) { try Self.decodeRow($0) }.first
    }

    /// Edges leaving `from`. Optional `type` narrows by edge type. Uses `idx_edges_from`.
    public func fetchOutgoing(from: NodeID, type: String?) throws -> [Edge] {
        try fetchByEndpoint(column: "from_id", id: from, type: type)
    }

    /// Edges arriving at `to`. Optional `type` narrows by edge type. Uses `idx_edges_to`.
    public func fetchIncoming(to: NodeID, type: String?) throws -> [Edge] {
        try fetchByEndpoint(column: "to_id", id: to, type: type)
    }

    public func fetchAll(type: String) throws -> [Edge] {
        try store.query(
            """
            SELECT id, type, from_id, to_id, properties, created_at, modified_at
            FROM edges
            WHERE type = ? AND is_deleted = 0
            """,
            [.text(type)]
        ) { try Self.decodeRow($0) }
    }

    // MARK: - Update

    public func update(id: EdgeID, properties patch: [String: PropertyValue]) throws {
        guard let existing = try fetch(id: id) else {
            throw RepositoryError.notFound(id: id.uuidString)
        }
        var merged = existing.properties
        for (k, v) in patch { merged[k] = v }
        let blob = try PropertyCoding.encode(merged)
        try store.execute(
            """
            UPDATE edges
            SET properties = ?, modified_at = ?
            WHERE id = ? AND is_deleted = 0
            """,
            [
                .blob(blob),
                .real(Date().timeIntervalSince1970),
                .text(id.uuidString),
            ]
        )
    }

    // MARK: - Delete (soft)

    public func delete(id: EdgeID) throws {
        try store.execute(
            """
            UPDATE edges
            SET is_deleted = 1, modified_at = ?
            WHERE id = ?
            """,
            [
                .real(Date().timeIntervalSince1970),
                .text(id.uuidString),
            ]
        )
    }

    // MARK: - Internals

    private func fetchByEndpoint(column: String, id: NodeID, type: String?) throws -> [Edge] {
        if let type {
            return try store.query(
                """
                SELECT id, type, from_id, to_id, properties, created_at, modified_at
                FROM edges
                WHERE \(column) = ? AND type = ? AND is_deleted = 0
                """,
                [.text(id.uuidString), .text(type)]
            ) { try Self.decodeRow($0) }
        } else {
            return try store.query(
                """
                SELECT id, type, from_id, to_id, properties, created_at, modified_at
                FROM edges
                WHERE \(column) = ? AND is_deleted = 0
                """,
                [.text(id.uuidString)]
            ) { try Self.decodeRow($0) }
        }
    }

    private func ensureNodeExists(id: NodeID) throws {
        let rows = try store.query(
            "SELECT 1 FROM nodes WHERE id = ? AND is_deleted = 0",
            [.text(id.uuidString)]
        ) { _ in 1 }
        if rows.isEmpty {
            throw RepositoryError.endpointMissing(id: id.uuidString)
        }
    }

    private static func decodeRow(_ row: SQLiteStore.Row) throws -> Edge {
        guard let idString = row.text(at: 0), let id = UUID(uuidString: idString),
              let type = row.text(at: 1),
              let fromString = row.text(at: 2), let fromID = UUID(uuidString: fromString),
              let toString = row.text(at: 3), let toID = UUID(uuidString: toString),
              let blob = row.blob(at: 4),
              let createdAtRaw = row.double(at: 5),
              let modifiedAtRaw = row.double(at: 6)
        else {
            throw RepositoryError.malformedRow
        }
        return Edge(
            id: id,
            type: type,
            fromID: fromID,
            toID: toID,
            properties: try PropertyCoding.decode(blob),
            createdAt: Date(timeIntervalSince1970: createdAtRaw),
            modifiedAt: Date(timeIntervalSince1970: modifiedAtRaw)
        )
    }
}
