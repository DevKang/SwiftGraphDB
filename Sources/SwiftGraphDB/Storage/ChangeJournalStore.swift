import Foundation

/// One row in `change_journal`. The on-disk representation is the canonical durable
/// representation; M8's `GraphChange` is a richer Swift wrapper.
public struct ChangeJournalRow: Sendable, Equatable {
    public let sequence: Int64
    public let changeID: ChangeID
    public let graphID: GraphID
    public let actorID: ActorID
    public let entityKind: EntityKind
    public let entityID: UUID
    public let operation: GraphOperation
    public let payload: Data?
    public let baseRevision: GraphRevision?
    public let revision: GraphRevision
    public let createdAt: Date

    public enum EntityKind: String, Sendable, Codable {
        case node, edge
    }
}

/// Read/append API over the durable change journal. The graph actor (`GraphActor`) calls
/// `append(_:)` inside the same SQLite transaction as the entity row write so crashes never
/// leave a journal row without a matching entity row or vice versa.
public struct ChangeJournalStore: Sendable {
    public let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    /// Append a row. Throws on `change_id` UNIQUE collision (idempotency check).
    public func append(_ row: ChangeJournalRow) throws {
        let revisionJSON = try Self.encodeRevision(row.revision)
        let baseJSON = try row.baseRevision.map(Self.encodeRevision)
        try store.execute(
            """
            INSERT INTO change_journal
            (change_id, graph_id, actor_id, entity_kind, entity_id, operation,
             payload, base_revision, revision, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(row.changeID.uuidString),
                .text(row.graphID.uuidString),
                .text(row.actorID.uuidString),
                .text(row.entityKind.rawValue),
                .text(row.entityID.uuidString),
                .text(row.operation.rawValue),
                row.payload.map(SQLValue.blob) ?? .null,
                baseJSON.map(SQLValue.text) ?? .null,
                .text(revisionJSON),
                .real(row.createdAt.timeIntervalSince1970),
            ]
        )
    }

    /// Walk rows in `sequence` order strictly greater than `cursor`. Used by sync push.
    public func iterate(after cursor: Int64) throws -> [ChangeJournalRow] {
        try store.query(
            """
            SELECT sequence, change_id, graph_id, actor_id, entity_kind, entity_id,
                   operation, payload, base_revision, revision, created_at
            FROM change_journal
            WHERE sequence > ?
            ORDER BY sequence
            """,
            [.integer(cursor)]
        ) { try Self.decode($0) }
    }

    /// Return the row for the given entity, or nil if none exists.
    public func latestRow(forEntity kind: ChangeJournalRow.EntityKind, id: UUID) throws -> ChangeJournalRow? {
        try store.query(
            """
            SELECT sequence, change_id, graph_id, actor_id, entity_kind, entity_id,
                   operation, payload, base_revision, revision, created_at
            FROM change_journal
            WHERE entity_kind = ? AND entity_id = ?
            ORDER BY sequence DESC LIMIT 1
            """,
            [.text(kind.rawValue), .text(id.uuidString)]
        ) { try Self.decode($0) }.first
    }

    public func count() throws -> Int {
        let rows = try store.query("SELECT COUNT(*) FROM change_journal") { $0.int(at: 0) ?? 0 }
        return Int(rows.first ?? 0)
    }

    // MARK: - Internals

    private static func encodeRevision(_ revision: GraphRevision) throws -> String {
        let data = try JSONEncoder().encode(revision)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func decodeRevision(_ json: String) throws -> GraphRevision {
        try JSONDecoder().decode(GraphRevision.self, from: Data(json.utf8))
    }

    private static func decode(_ row: SQLiteStore.Row) throws -> ChangeJournalRow {
        guard
            let sequence = row.int(at: 0),
            let changeIDStr = row.text(at: 1), let changeID = UUID(uuidString: changeIDStr),
            let graphIDStr = row.text(at: 2), let graphID = UUID(uuidString: graphIDStr),
            let actorIDStr = row.text(at: 3), let actorID = UUID(uuidString: actorIDStr),
            let entityKindStr = row.text(at: 4),
            let entityKind = ChangeJournalRow.EntityKind(rawValue: entityKindStr),
            let entityIDStr = row.text(at: 5), let entityID = UUID(uuidString: entityIDStr),
            let opStr = row.text(at: 6), let operation = GraphOperation(rawValue: opStr),
            let revisionJSON = row.text(at: 9),
            let createdAtRaw = row.double(at: 10)
        else {
            throw RepositoryError.malformedRow
        }
        let payload = row.blob(at: 7)
        let baseRevision: GraphRevision? = try row.text(at: 8).flatMap {
            try $0.isEmpty ? nil : Self.decodeRevision($0)
        }
        return ChangeJournalRow(
            sequence: sequence,
            changeID: changeID,
            graphID: graphID,
            actorID: actorID,
            entityKind: entityKind,
            entityID: entityID,
            operation: operation,
            payload: payload,
            baseRevision: baseRevision,
            revision: try Self.decodeRevision(revisionJSON),
            createdAt: Date(timeIntervalSince1970: createdAtRaw)
        )
    }
}
