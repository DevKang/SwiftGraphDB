import Foundation

/// Reason an individual change was rejected by the backend. Adapters surface backend-specific
/// failures through these cases so the core sync loop can decide retry / surface / fail.
public enum SyncRejectionReason: Sendable, Equatable, Codable {
    /// The remote already has a newer version of this entity. `remote` is the conflicting
    /// payload; `base` is the last known common ancestor (if the adapter tracks one).
    case conflict(remote: GraphRecordPayload, base: GraphRecordPayload?)
    /// The change failed validation against backend rules (e.g. an unsupported field).
    case validationFailed(String)
    /// The transport failed but the change is safe to retry later (network drop, throttling).
    case transient(String)
    /// The change cannot succeed regardless of retries (auth, permanent payload format).
    case permanent(String)
}

public struct SyncRejection: Sendable {
    public let changeID: ChangeID
    public let reason: SyncRejectionReason
    public init(changeID: ChangeID, reason: SyncRejectionReason) {
        self.changeID = changeID
        self.reason = reason
    }
}

/// Result of a transport's `push`. The set of accepted IDs marks them as synced; rejections
/// stay in the journal for re-processing per their reason.
public struct PushResult: Sendable {
    public let accepted: [ChangeID]
    public let rejected: [SyncRejection]
    public let checkpoint: SyncCheckpoint?
    public init(accepted: [ChangeID], rejected: [SyncRejection], checkpoint: SyncCheckpoint?) {
        self.accepted = accepted
        self.rejected = rejected
        self.checkpoint = checkpoint
    }
}

public struct PullResult: Sendable {
    public let changes: [GraphChange]
    public let checkpoint: SyncCheckpoint
    public let hasMore: Bool
    public init(changes: [GraphChange], checkpoint: SyncCheckpoint, hasMore: Bool) {
        self.changes = changes
        self.checkpoint = checkpoint
        self.hasMore = hasMore
    }
}

/// The single boundary between the core sync loop and a concrete backend (CloudKit, REST,
/// Firebase, an in-memory fake, etc.).
///
/// Implementations are responsible for **transport** only:
/// - serialise `ChangeBatch` to backend-specific records / requests
/// - apply backend retry / throttling rules
/// - return checkpoints opaque to core
/// - surface conflicts as `.conflict(remote:base:)` rather than applying them
public protocol GraphSyncTransport: Sendable {
    var backendID: SyncBackendID { get }
    func push(_ batch: ChangeBatch) async throws -> PushResult
    func pull(since checkpoint: SyncCheckpoint?) async throws -> PullResult
}
