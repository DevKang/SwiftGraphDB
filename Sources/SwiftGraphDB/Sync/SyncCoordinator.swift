import Foundation

/// One coordinator per `(GraphStore, GraphSyncTransport)` pair. Drives the SPEC §9.7 loop:
/// journal → push → mark accepted → pull → resolve → checkpoint. Multiple coordinators run
/// independently — backend cursors live in `sync_checkpoints` keyed by `backendID`.
public actor SyncCoordinator {

    public let backendID: SyncBackendID
    public let transport: GraphSyncTransport
    public let resolver: GraphConflictResolver
    private let graph: GraphActor
    /// Optional handler called when a conflict is detected during pull, before resolution.
    public var onConflict: (@Sendable (GraphConflict) -> Void)?

    public init(
        graph: GraphActor,
        transport: GraphSyncTransport,
        resolver: GraphConflictResolver
    ) {
        self.graph = graph
        self.transport = transport
        self.resolver = resolver
        self.backendID = transport.backendID
    }

    public func setOnConflict(_ handler: @escaping @Sendable (GraphConflict) -> Void) {
        self.onConflict = handler
    }

    /// One full sync round. Returns the count of (pushed, applied) changes.
    @discardableResult
    public func runOnce(maxBatchSize: Int = 256) async throws -> (pushed: Int, applied: Int) {
        let store = await graph.unsafeStoreForTests
        let metadata = SyncMetadataStore(store: store)
        let journal = ChangeJournalStore(store: store)
        let graphID = try await graph.graphIDForCoordinator()

        // 1–3. Push uncommitted local rows.
        let (storedCheckpoint, highWatermark) = try metadata.loadCheckpoint(backendID: backendID)
        let pendingRows = try journal.iterate(after: highWatermark)
        var pushed = 0
        var newWatermark = highWatermark
        if !pendingRows.isEmpty {
            let chunked = stride(from: 0, to: pendingRows.count, by: maxBatchSize).map {
                Array(pendingRows[$0..<min($0 + maxBatchSize, pendingRows.count)])
            }
            for chunk in chunked {
                let changes = chunk.map(GraphChange.init(from:))
                let batch = ChangeBatch(
                    graphID: graphID,
                    backendID: backendID,
                    changes: changes,
                    highWatermark: newWatermark
                )
                let result = try await transport.push(batch)
                let acceptedSet = Set(result.accepted)
                for row in chunk where acceptedSet.contains(row.changeID) {
                    pushed += 1
                    newWatermark = max(newWatermark, row.sequence)
                    if let payload = row.payload {
                        try metadata.saveRecordVersion(
                            backendID: backendID,
                            kind: row.entityKind,
                            id: row.entityID,
                            revision: row.revision,
                            basePayload: payload
                        )
                    }
                }
                if let cp = result.checkpoint {
                    try metadata.saveCheckpoint(cp, highWatermark: newWatermark)
                } else {
                    try metadata.saveCheckpoint(storedCheckpoint, highWatermark: newWatermark)
                }
                // Surface non-conflict rejections as thrown errors? The contract says they
                // stay in the journal — re-pushed next round. That's free here because
                // newWatermark only advances for accepted rows.
            }
        }

        // 4–6. Pull remote changes since the stored checkpoint.
        var applied = 0
        let (storedAfterPush, _) = try metadata.loadCheckpoint(backendID: backendID)
        var cursor = storedAfterPush
        var moreToPull = true
        while moreToPull {
            let pulled = try await transport.pull(since: cursor)
            for change in pulled.changes {
                try await applyRemoteChange(change, metadata: metadata)
                applied += 1
            }
            try metadata.saveCheckpoint(pulled.checkpoint, highWatermark: newWatermark)
            cursor = pulled.checkpoint
            moreToPull = pulled.hasMore
        }

        return (pushed, applied)
    }

    private func applyRemoteChange(_ change: GraphChange, metadata: SyncMetadataStore) async throws {
        let kind: ChangeJournalRow.EntityKind = (change.entity.kind == .node) ? .node : .edge
        let stored = try metadata.loadRecordVersion(backendID: backendID, kind: kind, id: change.entity.id)
        let basePayload: GraphRecordPayload? = stored.flatMap { (_, blob) in
            blob.flatMap { try? JSONDecoder().decode(GraphRecordPayload.self, from: $0) }
        }

        let localPayload = try await graph.fetchPayloadForCoordinator(kind: kind, id: change.entity.id)

        // No conflict iff there is no local divergence from the stored base.
        let localChanged = localPayload != basePayload && localPayload != nil
        let conflict = GraphConflict(
            backendID: backendID,
            entity: change.entity,
            base: basePayload,
            local: localPayload,
            remote: change.payload ?? GraphRecordPayload(properties: [:])
        )

        let resolution: GraphConflictResolution
        if !localChanged && change.operation == .upsert {
            // Trivial fast path — no local divergence, just accept the remote.
            resolution = .useRemote
        } else if change.operation == .delete && localChanged {
            onConflict?(conflict)
            resolution = try await resolver.resolve(conflict)
        } else if change.operation == .upsert && localChanged {
            onConflict?(conflict)
            resolution = try await resolver.resolve(conflict)
        } else {
            // Local also nil; remote delete just confirms the absent state.
            resolution = .useRemote
        }

        switch resolution {
        case .useRemote:
            try await graph.applyRemoteChangeForCoordinator(change)
        case .useLocal:
            // Skip — keep current local state.
            break
        case .merge(let merged):
            try await graph.applyMergedPayloadForCoordinator(
                kind: change.entity.kind, id: change.entity.id, payload: merged
            )
        case .delete:
            try await graph.deleteForCoordinator(kind: change.entity.kind, id: change.entity.id)
        case .fail(let reason):
            throw SyncCoordinatorError.unresolvedConflict(reason)
        }

        // Update sync_record_versions to track the new common base.
        let now = change.payload ?? GraphRecordPayload(properties: [:])
        let nowBytes = try? JSONEncoder().encode(now)
        try metadata.saveRecordVersion(
            backendID: backendID,
            kind: kind,
            id: change.entity.id,
            revision: change.revision,
            basePayload: nowBytes
        )
    }
}

/// Errors raised by `SyncCoordinator.runOnce` when a conflict cannot be resolved.
public enum SyncCoordinatorError: Error, Equatable {
    case unresolvedConflict(String)
}


