import Foundation
import SwiftGraphDB

/// `GraphSyncTransport` implementation backed by a `CloudKitDatabase`. The reference production
/// wiring uses a CKSyncEngine-backed database; tests inject a `MockCloudKitDatabase`.
///
/// The transport itself is stateless apart from configuration — it owns no checkpoints. Cursor
/// bytes (the CloudKit server change token) round-trip through `SyncCheckpoint.data`, opaque to
/// core. Backoff state lives on the call stack of the in-flight push / pull task only; the
/// foreground writer keeps draining into the journal while the transport sleeps.
public struct CloudKitGraphSyncTransport: GraphSyncTransport, Sendable {

    /// Tunables for batch chunking and backoff. Defaults match Apple's CloudKit guidance.
    public struct Configuration: Sendable {
        /// Maximum records per `modify` call. CloudKit caps individual operations around 400;
        /// 300 leaves headroom for save+delete combined.
        public var maxBatchSize: Int
        /// Initial backoff for `rateLimited` / `serviceUnavailable` when the server didn't
        /// supply a `retryAfter`. Doubled per attempt up to `maxBackoff`.
        public var initialBackoff: TimeInterval
        /// Hard ceiling for any single sleep. SPEC §14.5 sets this at 5 minutes.
        public var maxBackoff: TimeInterval
        /// Stop retrying after this many consecutive throttle responses for one batch. Beyond
        /// this we surface the changes as `.transient` so the registry switches to .offline.
        public var maxBackoffAttempts: Int
        public var clock: any TransportClock

        public init(
            maxBatchSize: Int = 300,
            initialBackoff: TimeInterval = 1.0,
            maxBackoff: TimeInterval = 300.0,
            maxBackoffAttempts: Int = 6,
            clock: any TransportClock = SystemTransportClock()
        ) {
            self.maxBatchSize = maxBatchSize
            self.initialBackoff = initialBackoff
            self.maxBackoff = maxBackoff
            self.maxBackoffAttempts = maxBackoffAttempts
            self.clock = clock
        }
    }

    public let backendID: SyncBackendID
    private let database: any CloudKitDatabase
    public let configuration: Configuration

    public init(
        backendID: SyncBackendID,
        database: any CloudKitDatabase,
        configuration: Configuration = Configuration()
    ) {
        self.backendID = backendID
        self.database = database
        self.configuration = configuration
    }

    public func push(_ batch: ChangeBatch) async throws -> PushResult {
        // 1. Slice the batch into config-sized chunks up-front. Each chunk goes through its own
        //    retry/split state machine. We accumulate results across all chunks.
        let chunks = chunked(batch.changes, by: configuration.maxBatchSize)
        var allAccepted: [ChangeID] = []
        var allRejected: [SyncRejection] = []
        for chunk in chunks {
            let (accepted, rejected) = try await pushChunkWithRetry(chunk, attempt: 0)
            allAccepted.append(contentsOf: accepted)
            allRejected.append(contentsOf: rejected)
        }
        return PushResult(accepted: allAccepted, rejected: allRejected, checkpoint: nil)
    }

    private func pushChunkWithRetry(
        _ changes: [GraphChange],
        attempt: Int
    ) async throws -> (accepted: [ChangeID], rejected: [SyncRejection]) {
        guard !changes.isEmpty else { return ([], []) }

        var savingRecords: [CloudKitRecord] = []
        var savingChangeIDs: [CloudKitRecordID: ChangeID] = [:]
        var deletingRecordIDs: [CloudKitRecordID] = []
        var deletingChangeIDs: [CloudKitRecordID: ChangeID] = [:]

        for change in changes {
            switch change.operation {
            case .upsert:
                let record = try RecordCodec.encode(change)
                savingRecords.append(record)
                savingChangeIDs[record.id] = change.id
            case .delete:
                let id = CloudKitRecordID.make(from: change.entity)
                deletingRecordIDs.append(id)
                deletingChangeIDs[id] = change.id
            }
        }

        let result: CloudKitModifyResult
        do {
            result = try await database.modify(
                savingRecords: savingRecords,
                deletingRecordIDs: deletingRecordIDs
            )
        } catch let error as CloudKitTransportError {
            switch error {
            case .limitExceeded:
                // CloudKit refused the batch. Halve and retry both halves. With a single record
                // we can't split further — surface as transient.
                if changes.count <= 1 {
                    return ([], changes.map {
                        SyncRejection(changeID: $0.id, reason: .transient("limit exceeded for single record"))
                    })
                }
                let mid = changes.count / 2
                let firstHalf = Array(changes.prefix(mid))
                let secondHalf = Array(changes.suffix(from: mid))
                let (a1, r1) = try await pushChunkWithRetry(firstHalf, attempt: 0)
                let (a2, r2) = try await pushChunkWithRetry(secondHalf, attempt: 0)
                return (a1 + a2, r1 + r2)

            case .rateLimited, .serviceUnavailable:
                if attempt >= configuration.maxBackoffAttempts {
                    return ([], changes.map {
                        SyncRejection(changeID: $0.id, reason: .transient(error.reason))
                    })
                }
                let hint: TimeInterval?
                switch error {
                case .rateLimited(let r): hint = r
                case .serviceUnavailable(let r): hint = r
                default: hint = nil
                }
                let delay = backoffDelay(retryAfter: hint, attempt: attempt)
                try await configuration.clock.sleep(seconds: delay)
                return try await pushChunkWithRetry(changes, attempt: attempt + 1)

            case .networkFailure, .throttled:
                // Plain transient — surface for the next sync round to retry.
                return ([], changes.map {
                    SyncRejection(changeID: $0.id, reason: .transient(error.reason))
                })
            }
        }

        var accepted: [ChangeID] = []
        var rejected: [SyncRejection] = []
        let conflictedIDs = Set(result.conflicts.map { $0.record.id })

        for record in result.saved where !conflictedIDs.contains(record.id) {
            if let id = savingChangeIDs[record.id] {
                accepted.append(id)
            }
        }
        for id in result.deleted {
            if let cid = deletingChangeIDs[id] {
                accepted.append(cid)
            }
        }
        for conflict in result.conflicts {
            guard let cid = savingChangeIDs[conflict.record.id] else { continue }
            let remoteChange = (try? RecordCodec.decode(conflict.serverRecord))
            let remotePayload = remoteChange?.payload ?? GraphRecordPayload(properties: [:])
            rejected.append(SyncRejection(
                changeID: cid,
                reason: .conflict(remote: remotePayload, base: nil)
            ))
        }

        return (accepted, rejected)
    }

    private func backoffDelay(retryAfter: TimeInterval?, attempt: Int) -> TimeInterval {
        if let hint = retryAfter, hint > 0 {
            return min(hint, configuration.maxBackoff)
        }
        let exponential = configuration.initialBackoff * pow(2.0, Double(attempt))
        return min(exponential, configuration.maxBackoff)
    }

    public func pull(since checkpoint: SyncCheckpoint?) async throws -> PullResult {
        let token = checkpoint?.data
        let fetched = try await database.fetchChanges(sinceServerChangeToken: token)

        var changes: [GraphChange] = []
        for record in fetched.changedRecords {
            do {
                changes.append(try RecordCodec.decode(record))
            } catch {
                // Permanent decode error: skip this record. The next fetch with the new token
                // won't return it, so dropping is correct under "transport tracks tokens".
                continue
            }
        }
        for recordID in fetched.deletedRecordIDs {
            guard let entity = recordID.entity else { continue }
            let actor = ActorID()
            let revision = GraphRevision(actorID: actor, counter: 0, wallClock: Date())
            changes.append(GraphChange(
                id: UUID(), graphID: UUID(), actorID: actor,
                sequence: 0, entity: entity, operation: .delete,
                payload: nil, baseRevision: nil, revision: revision,
                createdAt: Date()
            ))
        }

        let cp = SyncCheckpoint(backendID: backendID, data: fetched.serverChangeToken)
        return PullResult(changes: changes, checkpoint: cp, hasMore: fetched.moreComing)
    }
}

private func chunked<T>(_ array: [T], by size: Int) -> [[T]] {
    guard size > 0, !array.isEmpty else { return array.isEmpty ? [] : [array] }
    return stride(from: 0, to: array.count, by: size).map {
        Array(array[$0..<min($0 + size, array.count)])
    }
}

// MARK: - Errors

/// Adapter-side error surface for CloudKit failures the transport handles specially. Production
/// code maps `CKError` cases into these; tests inject them directly via `MockCloudKitDatabase`.
public enum CloudKitTransportError: Error, Sendable, Equatable {
    /// Network unreachable. Surface as `.transient` for the next sync round.
    case networkFailure
    /// `CKError.serviceUnavailable` — server-side outage. Optional `retryAfter` hint.
    case serviceUnavailable(retryAfter: TimeInterval?)
    /// `CKError.requestRateLimited` / zoneBusy — back off then retry.
    case rateLimited(retryAfter: TimeInterval)
    /// `CKError.limitExceeded` — batch too big; transport halves and retries.
    case limitExceeded
    /// CloudKit signaled a generic throttle without retry hint.
    case throttled

    public var reason: String {
        switch self {
        case .networkFailure: return "network failure"
        case .serviceUnavailable: return "service unavailable"
        case .rateLimited: return "rate limited"
        case .limitExceeded: return "limit exceeded"
        case .throttled: return "throttled"
        }
    }
}

// MARK: - Clock

/// Injectable sleep abstraction so tests can verify backoff timing without real-time waits.
public protocol TransportClock: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemTransportClock: TransportClock {
    public init() {}
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
