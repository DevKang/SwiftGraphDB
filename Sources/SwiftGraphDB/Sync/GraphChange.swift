import Foundation

/// Discriminator for whether a `GraphEntityRef` points at a node or an edge.
public enum GraphEntityKind: String, Codable, Sendable, Hashable {
    case node, edge
}

/// Reference to a graph entity by `(kind, id)`. Distinguishes node-IDs from edge-IDs across
/// adapter boundaries even though both are UUIDs.
public struct GraphEntityRef: Codable, Sendable, Hashable {
    public let kind: GraphEntityKind
    public let id: UUID
    public init(kind: GraphEntityKind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}

/// One row of payload data for an upsert change. Covers both node and edge shapes — adapters
/// can read the relevant fields based on `entity.kind`.
public struct GraphRecordPayload: Codable, Sendable, Hashable {
    public var format: PayloadFormatVersion
    public var properties: [String: PropertyValue]
    public var label: String?       // node only
    public var type: String?        // edge only
    public var fromID: NodeID?      // edge only
    public var toID: NodeID?        // edge only

    public init(
        format: PayloadFormatVersion = .current,
        properties: [String: PropertyValue],
        label: String? = nil,
        type: String? = nil,
        fromID: NodeID? = nil,
        toID: NodeID? = nil
    ) {
        self.format = format
        self.properties = properties
        self.label = label
        self.type = type
        self.fromID = fromID
        self.toID = toID
    }
}

/// One committed mutation, expressed in the backend-agnostic shape transports exchange.
public struct GraphChange: Codable, Sendable, Hashable {
    public let id: ChangeID
    public let graphID: GraphID
    public let actorID: ActorID
    public let sequence: Int64
    public let entity: GraphEntityRef
    public let operation: GraphOperation
    public let payload: GraphRecordPayload?
    public let baseRevision: GraphRevision?
    public let revision: GraphRevision
    public let createdAt: Date

    public init(
        id: ChangeID,
        graphID: GraphID,
        actorID: ActorID,
        sequence: Int64,
        entity: GraphEntityRef,
        operation: GraphOperation,
        payload: GraphRecordPayload?,
        baseRevision: GraphRevision?,
        revision: GraphRevision,
        createdAt: Date
    ) {
        self.id = id
        self.graphID = graphID
        self.actorID = actorID
        self.sequence = sequence
        self.entity = entity
        self.operation = operation
        self.payload = payload
        self.baseRevision = baseRevision
        self.revision = revision
        self.createdAt = createdAt
    }

    /// Validate that the upsert/delete payload invariant holds. Adapters should call this
    /// before serialising or after decoding.
    public func validate() throws {
        switch operation {
        case .upsert:
            guard payload != nil else {
                throw GraphChangeError.upsertMissingPayload
            }
        case .delete:
            // payload may be nil; adapters that ship payloads on deletes (e.g. for tombstone
            // contexts) are still legal but the absence is the canonical case.
            break
        }
    }
}

/// Errors raised when validating or decoding a `GraphChange`.
public enum GraphChangeError: Error, Equatable {
    case upsertMissingPayload
    case unsupportedPayloadFormat(found: PayloadFormatVersion)
}

/// Bounded batch of changes for one push call.
public struct ChangeBatch: Codable, Sendable {
    public let graphID: GraphID
    public let backendID: SyncBackendID
    public let changes: [GraphChange]
    public let highWatermark: Int64

    public init(graphID: GraphID, backendID: SyncBackendID, changes: [GraphChange], highWatermark: Int64) {
        self.graphID = graphID
        self.backendID = backendID
        self.changes = changes
        self.highWatermark = highWatermark
    }
}

/// Opaque, backend-defined cursor. Bytes are not interpreted by the core sync loop.
public struct SyncCheckpoint: Codable, Sendable, Hashable {
    public let backendID: SyncBackendID
    public let data: Data
    public init(backendID: SyncBackendID, data: Data) {
        self.backendID = backendID
        self.data = data
    }
}

extension GraphChange {
    /// Convenience: build a `GraphChange` from a durable `change_journal` row plus the actor's
    /// graph context. Used by the sync loop when assembling push batches.
    public init(from row: ChangeJournalRow) {
        let entityKind: GraphEntityKind = (row.entityKind == .node) ? .node : .edge
        var payload: GraphRecordPayload?
        if row.operation == .upsert, let blob = row.payload {
            // Try the v2 GraphRecordPayload shape first; fall back to bare property dict for
            // forward compatibility with anything that wrote a non-payload BLOB.
            if let p = try? JSONDecoder().decode(GraphRecordPayload.self, from: blob) {
                payload = p
            } else if let dict = try? PropertyCoding.decode(blob) {
                payload = GraphRecordPayload(properties: dict)
            }
        }
        self.init(
            id: row.changeID,
            graphID: row.graphID,
            actorID: row.actorID,
            sequence: row.sequence,
            entity: GraphEntityRef(kind: entityKind, id: row.entityID),
            operation: row.operation,
            payload: payload,
            baseRevision: row.baseRevision,
            revision: row.revision,
            createdAt: row.createdAt
        )
    }
}
