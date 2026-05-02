import Foundation

/// SQLite façade for `sync_checkpoints` and `sync_record_versions`. Owned by the sync loop;
/// mutations happen inside the same SQLite transaction as the matching `change_journal`
/// updates so a crash never leaves a checkpoint pointing past unapplied changes.
public struct SyncMetadataStore: Sendable {
    public let store: SQLiteStore
    public init(store: SQLiteStore) { self.store = store }

    public func loadCheckpoint(backendID: SyncBackendID) throws -> (checkpoint: SyncCheckpoint?, highWatermark: Int64) {
        let rows = try store.query(
            "SELECT checkpoint, high_watermark FROM sync_checkpoints WHERE backend_id = ?",
            [.text(backendID.rawValue)]
        ) { row -> (Data?, Int64) in
            (row.blob(at: 0), row.int(at: 1) ?? 0)
        }
        guard let (data, hwm) = rows.first else { return (nil, 0) }
        let checkpoint = data.map { SyncCheckpoint(backendID: backendID, data: $0) }
        return (checkpoint, hwm)
    }

    public func saveCheckpoint(_ checkpoint: SyncCheckpoint?, highWatermark: Int64) throws {
        let id = checkpoint?.backendID ?? SyncBackendID("")
        try store.execute(
            """
            INSERT INTO sync_checkpoints (backend_id, checkpoint, high_watermark, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(backend_id) DO UPDATE SET
                checkpoint = excluded.checkpoint,
                high_watermark = excluded.high_watermark,
                updated_at = excluded.updated_at
            """,
            [
                .text(id.rawValue),
                checkpoint.map { SQLValue.blob($0.data) } ?? .null,
                .integer(highWatermark),
                .real(Date().timeIntervalSince1970),
            ]
        )
    }

    public func loadRecordVersion(backendID: SyncBackendID, kind: ChangeJournalRow.EntityKind, id: UUID) throws -> (revision: GraphRevision, basePayload: Data?)? {
        let rows = try store.query(
            """
            SELECT last_synced_revision, base_payload
            FROM sync_record_versions
            WHERE backend_id = ? AND entity_kind = ? AND entity_id = ?
            """,
            [.text(backendID.rawValue), .text(kind.rawValue), .text(id.uuidString)]
        ) { row -> (String?, Data?) in
            (row.text(at: 0), row.blob(at: 1))
        }
        guard let (revText, blob) = rows.first,
              let revText, let data = revText.data(using: .utf8),
              let revision = try? JSONDecoder().decode(GraphRevision.self, from: data)
        else { return nil }
        return (revision, blob)
    }

    public func saveRecordVersion(
        backendID: SyncBackendID,
        kind: ChangeJournalRow.EntityKind,
        id: UUID,
        revision: GraphRevision,
        basePayload: Data?
    ) throws {
        let revisionJSON = String(data: try JSONEncoder().encode(revision), encoding: .utf8) ?? "{}"
        try store.execute(
            """
            INSERT INTO sync_record_versions (backend_id, entity_kind, entity_id, last_synced_revision, base_payload, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(backend_id, entity_kind, entity_id) DO UPDATE SET
                last_synced_revision = excluded.last_synced_revision,
                base_payload = excluded.base_payload,
                updated_at = excluded.updated_at
            """,
            [
                .text(backendID.rawValue),
                .text(kind.rawValue),
                .text(id.uuidString),
                .text(revisionJSON),
                basePayload.map { SQLValue.blob($0) } ?? .null,
                .real(Date().timeIntervalSince1970),
            ]
        )
    }
}
