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
    /// The persisted `revision` matches `node.revision` — callers (the graph actor) are
    /// expected to stamp a real revision before calling.
    public func insert(_ node: Node) throws {
        let json = try PropertyCoding.encodeToString(node.properties)
        let revisionJSON = try Self.encodeRevision(node.revision)
        let labelsJSON = try Self.encodeLabels(node.labels)
        try store.execute(
            """
            INSERT INTO nodes (id, label, labels, properties, created_at, modified_at, is_deleted, revision)
            VALUES (?, ?, ?, ?, ?, ?, 0, ?)
            """,
            [
                .text(node.id.uuidString),
                .text(node.label),
                .text(labelsJSON),
                .text(json),
                .real(node.createdAt.timeIntervalSince1970),
                .real(node.modifiedAt.timeIntervalSince1970),
                .text(revisionJSON),
            ]
        )
    }

    // MARK: - Fetch

    /// Returns the node, or `nil` if missing or soft-deleted.
    public func fetch(id: NodeID) throws -> Node? {
        let rows = try store.query(
            """
            SELECT id, label, properties, created_at, modified_at, revision, is_deleted, labels
            FROM nodes
            WHERE id = ? AND is_deleted = 0
            """,
            [.text(id.uuidString)]
        ) { try Self.decodeRow($0) }
        return rows.first
    }

    /// Fetch every live node with the given label. Checks both primary `label` and `labels` array.
    public func fetchAll(label: String) throws -> [Node] {
        try store.query(
            """
            SELECT id, label, properties, created_at, modified_at, revision, is_deleted, labels
            FROM nodes
            WHERE is_deleted = 0
              AND (label = ? OR EXISTS (
                SELECT 1 FROM json_each(labels) WHERE json_each.value = ?
              ))
            """,
            [.text(label), .text(label)]
        ) { try Self.decodeRow($0) }
    }

    // MARK: - Update

    /// Merge `properties` into the existing row's properties, bump `modified_at`, and stamp
    /// the new `revision`. Throws if the node does not exist or is soft-deleted (no silent
    /// no-op). Throws `RepositoryError.placeholderRevision` if the caller hands in
    /// `GraphRevision.placeholder` — committers must stamp a real revision first.
    public func update(id: NodeID, properties patch: [String: PropertyValue], revision: GraphRevision) throws {
        try Self.requireRealRevision(revision)
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
            UPDATE nodes
            SET properties = ?, modified_at = ?, revision = ?
            WHERE id = ? AND is_deleted = 0
            """,
            [
                .text(json),
                .real(Date().timeIntervalSince1970),
                .text(try Self.encodeRevision(revision)),
                .text(id.uuidString),
            ]
        )
    }

    // MARK: - Label operations

    /// Add a label to an existing node.
    public func addLabel(_ label: String, to id: NodeID, revision: GraphRevision) throws {
        try Self.requireRealRevision(revision)
        guard let existing = try fetch(id: id) else {
            throw RepositoryError.notFound(id: id.uuidString)
        }
        var newLabels = existing.labels
        newLabels.insert(label)
        let labelsJSON = try Self.encodeLabels(newLabels)
        let primaryLabel = newLabels.sorted().first ?? label
        try store.execute(
            """
            UPDATE nodes
            SET label = ?, labels = ?, modified_at = ?, revision = ?
            WHERE id = ? AND is_deleted = 0
            """,
            [
                .text(primaryLabel),
                .text(labelsJSON),
                .real(Date().timeIntervalSince1970),
                .text(try Self.encodeRevision(revision)),
                .text(id.uuidString),
            ]
        )
    }

    /// Remove a label from an existing node. The node must retain at least one label.
    public func removeLabel(_ label: String, from id: NodeID, revision: GraphRevision) throws {
        try Self.requireRealRevision(revision)
        guard let existing = try fetch(id: id) else {
            throw RepositoryError.notFound(id: id.uuidString)
        }
        var newLabels = existing.labels
        newLabels.remove(label)
        guard !newLabels.isEmpty else {
            throw RepositoryError.lastLabelRemoval
        }
        let labelsJSON = try Self.encodeLabels(newLabels)
        let primaryLabel = newLabels.sorted().first ?? ""
        try store.execute(
            """
            UPDATE nodes
            SET label = ?, labels = ?, modified_at = ?, revision = ?
            WHERE id = ? AND is_deleted = 0
            """,
            [
                .text(primaryLabel),
                .text(labelsJSON),
                .real(Date().timeIntervalSince1970),
                .text(try Self.encodeRevision(revision)),
                .text(id.uuidString),
            ]
        )
    }

    // MARK: - Delete (soft)

    /// Soft-delete: mark `is_deleted = 1` and stamp the deleting actor's revision so
    /// tombstones carry their own logical version (sync needs this to propagate deletes).
    public func delete(id: NodeID, revision: GraphRevision) throws {
        try Self.requireRealRevision(revision)
        try store.execute(
            """
            UPDATE nodes
            SET is_deleted = 1, modified_at = ?, revision = ?
            WHERE id = ?
            """,
            [
                .real(Date().timeIntervalSince1970),
                .text(try Self.encodeRevision(revision)),
                .text(id.uuidString),
            ]
        )
    }

    // MARK: - Row decoding

    static func decodeRow(_ row: SQLiteStore.Row) throws -> Node {
        guard let idString = row.text(at: 0), let id = UUID(uuidString: idString),
              let label = row.text(at: 1),
              let propertiesJSON = row.text(at: 2),
              let createdAtRaw = row.double(at: 3),
              let modifiedAtRaw = row.double(at: 4)
        else {
            throw RepositoryError.malformedRow
        }
        let properties = try PropertyCoding.decodeFromString(propertiesJSON)
        let revisionJSON = row.text(at: 5)
        let isDeleted = (row.int(at: 6) ?? 0) != 0
        let revision: GraphRevision
        if let revisionJSON, let data = revisionJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(GraphRevision.self, from: data) {
            revision = decoded
        } else {
            revision = GraphRevision.placeholder(wallClock: Date(timeIntervalSince1970: modifiedAtRaw))
        }
        // Column 7: labels JSON array (v4+). Fall back to single label if missing.
        let labels: Set<String>
        if let labelsJSON = row.text(at: 7), let parsed = try? decodeLabels(labelsJSON), !parsed.isEmpty {
            labels = parsed
        } else {
            labels = [label]
        }
        return Node(
            id: id,
            labels: labels,
            properties: properties,
            createdAt: Date(timeIntervalSince1970: createdAtRaw),
            modifiedAt: Date(timeIntervalSince1970: modifiedAtRaw),
            revision: revision,
            isDeleted: isDeleted
        )
    }

    static func encodeRevision(_ revision: GraphRevision) throws -> String {
        let data = try JSONEncoder().encode(revision)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func encodeLabels(_ labels: Set<String>) throws -> String {
        let data = try JSONEncoder().encode(labels.sorted())
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func decodeLabels(_ json: String) throws -> Set<String> {
        guard let data = json.data(using: .utf8) else { return [] }
        let arr = try JSONDecoder().decode([String].self, from: data)
        return Set(arr)
    }

    static func requireRealRevision(_ revision: GraphRevision) throws {
        // Placeholder uses the zero UUID; reject so committers don't accidentally write it.
        let zero = ActorID(uuid: (0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0))
        if revision.actorID == zero && revision.counter == 0 {
            throw RepositoryError.placeholderRevision
        }
    }
}

/// Errors common to node and edge repositories.
public enum RepositoryError: Error, Equatable {
    case notFound(id: String)
    case endpointMissing(id: String)
    case malformedRow
    /// Caller passed `GraphRevision.placeholder` to a write that requires a stamped revision.
    /// The graph actor mints a real revision on commit; tests / SPI callers must do the same.
    case placeholderRevision
    /// Attempted to remove the last label from a node. Nodes must have at least one label.
    case lastLabelRemoval
}
