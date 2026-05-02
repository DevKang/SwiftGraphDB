import Foundation

/// A soft-deleted node or edge. `since` queries on `TombstoneStore` use `modifiedAt` so the
/// caller can iterate everything deleted after a given checkpoint. The deleting actor's
/// revision is preserved so sync code can ship the tombstone with its logical version.
public struct Tombstone: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case node, edge }

    public let id: UUID
    public let kind: Kind
    public let modifiedAt: Date
    public let revision: GraphRevision
}

/// Read-only view over the soft-deleted rows in `nodes` and `edges`.
///
/// Tombstones exist because CloudKit cannot reliably propagate "this row no longer exists" — a
/// delete must leave evidence on disk so other devices learn about it. They also keep the
/// in-memory rebuild path correct: if a deleted row stayed in SQLite as live, a fresh open
/// would resurrect it.
///
/// Hard-deletion / retention compaction is **not** implemented here.
/// // TODO(M8): once CloudKit sync is in place, design a retention window for tombstones (SPEC §15.4).
public struct TombstoneStore: Sendable {

    public let store: SQLiteStore

    public init(store: SQLiteStore) {
        self.store = store
    }

    /// Tombstones for nodes deleted at or after `since`.
    public func nodeTombstones(since: Date) throws -> [Tombstone] {
        try store.query(
            """
            SELECT id, modified_at, revision FROM nodes
            WHERE is_deleted = 1 AND modified_at >= ?
            ORDER BY modified_at
            """,
            [.real(since.timeIntervalSince1970)]
        ) { row in
            try decodeTombstone(row, kind: .node)
        }
    }

    /// Tombstones for edges deleted at or after `since`.
    public func edgeTombstones(since: Date) throws -> [Tombstone] {
        try store.query(
            """
            SELECT id, modified_at, revision FROM edges
            WHERE is_deleted = 1 AND modified_at >= ?
            ORDER BY modified_at
            """,
            [.real(since.timeIntervalSince1970)]
        ) { row in
            try decodeTombstone(row, kind: .edge)
        }
    }

    private func decodeTombstone(_ row: SQLiteStore.Row, kind: Tombstone.Kind) throws -> Tombstone {
        guard let idString = row.text(at: 0), let id = UUID(uuidString: idString),
              let modifiedAtRaw = row.double(at: 1)
        else {
            throw RepositoryError.malformedRow
        }
        let revisionJSON = row.text(at: 2)
        let revision: GraphRevision
        if let revisionJSON, let data = revisionJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(GraphRevision.self, from: data) {
            revision = decoded
        } else {
            revision = GraphRevision.placeholder(wallClock: Date(timeIntervalSince1970: modifiedAtRaw))
        }
        return Tombstone(
            id: id,
            kind: kind,
            modifiedAt: Date(timeIntervalSince1970: modifiedAtRaw),
            revision: revision
        )
    }
}
