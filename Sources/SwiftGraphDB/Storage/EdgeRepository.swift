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
        let json = try PropertyCoding.encodeToString(edge.properties)
        try store.execute(
            """
            INSERT INTO edges (id, type, from_id, to_id, properties, created_at, modified_at, is_deleted, revision)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)
            """,
            [
                .text(edge.id.uuidString),
                .text(edge.type),
                .text(edge.fromID.uuidString),
                .text(edge.toID.uuidString),
                .text(json),
                .real(edge.createdAt.timeIntervalSince1970),
                .real(edge.modifiedAt.timeIntervalSince1970),
                .text(try NodeRepository.encodeRevision(edge.revision)),
            ]
        )
    }

    // MARK: - Fetch

    public func fetch(id: EdgeID) throws -> Edge? {
        try store.query(
            """
            SELECT id, type, from_id, to_id, properties, created_at, modified_at, revision, is_deleted
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
            SELECT id, type, from_id, to_id, properties, created_at, modified_at, revision, is_deleted
            FROM edges
            WHERE type = ? AND is_deleted = 0
            """,
            [.text(type)]
        ) { try Self.decodeRow($0) }
    }

    // MARK: - Update

    public func update(id: EdgeID, properties patch: [String: PropertyValue], revision: GraphRevision) throws {
        try NodeRepository.requireRealRevision(revision)
        guard let existing = try fetch(id: id) else {
            throw RepositoryError.notFound(id: id.uuidString)
        }
        var merged = existing.properties
        for (k, v) in patch {
            if case .null = v { merged.removeValue(forKey: k) }
            else { merged[k] = v }
        }
        let json = try PropertyCoding.encodeToString(merged)
        try store.execute(
            """
            UPDATE edges
            SET properties = ?, modified_at = ?, revision = ?
            WHERE id = ? AND is_deleted = 0
            """,
            [
                .text(json),
                .real(Date().timeIntervalSince1970),
                .text(try NodeRepository.encodeRevision(revision)),
                .text(id.uuidString),
            ]
        )
    }

    // MARK: - Delete (soft)

    public func delete(id: EdgeID, revision: GraphRevision) throws {
        try NodeRepository.requireRealRevision(revision)
        try store.execute(
            """
            UPDATE edges
            SET is_deleted = 1, modified_at = ?, revision = ?
            WHERE id = ?
            """,
            [
                .real(Date().timeIntervalSince1970),
                .text(try NodeRepository.encodeRevision(revision)),
                .text(id.uuidString),
            ]
        )
    }

    // MARK: - Internals

    private func fetchByEndpoint(column: String, id: NodeID, type: String?) throws -> [Edge] {
        if let type {
            return try store.query(
                """
                SELECT id, type, from_id, to_id, properties, created_at, modified_at, revision, is_deleted
                FROM edges
                WHERE \(column) = ? AND type = ? AND is_deleted = 0
                """,
                [.text(id.uuidString), .text(type)]
            ) { try Self.decodeRow($0) }
        } else {
            return try store.query(
                """
                SELECT id, type, from_id, to_id, properties, created_at, modified_at, revision, is_deleted
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

    static func decodeRow(_ row: SQLiteStore.Row) throws -> Edge {
        guard let idString = row.text(at: 0), let id = UUID(uuidString: idString),
              let type = row.text(at: 1),
              let fromString = row.text(at: 2), let fromID = UUID(uuidString: fromString),
              let toString = row.text(at: 3), let toID = UUID(uuidString: toString),
              let propertiesJSON = row.text(at: 4),
              let createdAtRaw = row.double(at: 5),
              let modifiedAtRaw = row.double(at: 6)
        else {
            throw RepositoryError.malformedRow
        }
        let revisionJSON = row.text(at: 7)
        let isDeleted = (row.int(at: 8) ?? 0) != 0
        let revision: GraphRevision
        if let revisionJSON, let data = revisionJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(GraphRevision.self, from: data) {
            revision = decoded
        } else {
            revision = GraphRevision.placeholder(wallClock: Date(timeIntervalSince1970: modifiedAtRaw))
        }
        return Edge(
            id: id,
            type: type,
            fromID: fromID,
            toID: toID,
            properties: try PropertyCoding.decodeFromString(propertiesJSON),
            createdAt: Date(timeIntervalSince1970: createdAtRaw),
            modifiedAt: Date(timeIntervalSince1970: modifiedAtRaw),
            revision: revision,
            isDeleted: isDeleted
        )
    }
}
