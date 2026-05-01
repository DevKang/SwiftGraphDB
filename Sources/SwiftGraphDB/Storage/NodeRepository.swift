import Foundation

/// CRUD operations on the `nodes` SQLite table.
///
/// Soft delete is the default: `delete(id:)` sets `is_deleted = 1` and all read methods filter
/// the row out. The full tombstone semantics (rebuild contract, hard-delete retention policy)
/// live in `Tombstones.swift` (OML-1928).
public struct NodeRepository: Sendable {

    public let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    // MARK: - Insert

    /// Insert a node. Throws if a row with the same id already exists (soft-deleted or not).
    public func insert(_ node: Node) throws {
        let blob = try PropertyCoding.encode(node.properties)
        try store.execute(
            """
            INSERT INTO nodes (id, label, properties, created_at, modified_at, is_deleted)
            VALUES (?, ?, ?, ?, ?, 0)
            """,
            [
                .text(node.id.uuidString),
                .text(node.label),
                .blob(blob),
                .real(node.createdAt.timeIntervalSince1970),
                .real(node.modifiedAt.timeIntervalSince1970),
            ]
        )
    }

    // MARK: - Fetch

    /// Returns the node, or `nil` if missing or soft-deleted.
    public func fetch(id: NodeID) throws -> Node? {
        let rows = try store.query(
            """
            SELECT id, label, properties, created_at, modified_at
            FROM nodes
            WHERE id = ? AND is_deleted = 0
            """,
            [.text(id.uuidString)]
        ) { try Self.decodeRow($0) }
        return rows.first
    }

    /// Fetch every live node with the given label. Uses the `idx_nodes_label` partial index.
    public func fetchAll(label: String) throws -> [Node] {
        try store.query(
            """
            SELECT id, label, properties, created_at, modified_at
            FROM nodes
            WHERE label = ? AND is_deleted = 0
            """,
            [.text(label)]
        ) { try Self.decodeRow($0) }
    }

    // MARK: - Update

    /// Merge `properties` into the existing row's properties, then bump `modified_at`. Throws if
    /// the node does not exist or is soft-deleted (no silent no-op).
    public func update(id: NodeID, properties patch: [String: PropertyValue]) throws {
        guard let existing = try fetch(id: id) else {
            throw RepositoryError.notFound(id: id.uuidString)
        }
        var merged = existing.properties
        for (k, v) in patch { merged[k] = v }
        let blob = try PropertyCoding.encode(merged)
        try store.execute(
            """
            UPDATE nodes
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

    /// Soft-delete: mark `is_deleted = 1`. The row remains in the table for sync / rebuild.
    public func delete(id: NodeID) throws {
        try store.execute(
            """
            UPDATE nodes
            SET is_deleted = 1, modified_at = ?
            WHERE id = ?
            """,
            [
                .real(Date().timeIntervalSince1970),
                .text(id.uuidString),
            ]
        )
    }

    // MARK: - Row decoding

    private static func decodeRow(_ row: SQLiteStore.Row) throws -> Node {
        guard let idString = row.text(at: 0), let id = UUID(uuidString: idString),
              let label = row.text(at: 1),
              let blob = row.blob(at: 2),
              let createdAtRaw = row.double(at: 3),
              let modifiedAtRaw = row.double(at: 4)
        else {
            throw RepositoryError.malformedRow
        }
        let properties = try PropertyCoding.decode(blob)
        return Node(
            id: id,
            label: label,
            properties: properties,
            createdAt: Date(timeIntervalSince1970: createdAtRaw),
            modifiedAt: Date(timeIntervalSince1970: modifiedAtRaw)
        )
    }
}

/// Errors common to node and edge repositories.
public enum RepositoryError: Error, Equatable {
    case notFound(id: String)
    case endpointMissing(id: String)
    case malformedRow
}
