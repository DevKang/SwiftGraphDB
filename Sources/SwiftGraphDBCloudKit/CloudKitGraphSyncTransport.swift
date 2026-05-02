import Foundation
import SwiftGraphDB

/// `GraphSyncTransport` implementation backed by a `CloudKitDatabase`. The reference production
/// wiring uses a CKSyncEngine-backed database; tests inject a `MockCloudKitDatabase`.
///
/// The transport itself is stateless — it owns no checkpoints. Cursor bytes (the CloudKit server
/// change token) round-trip through `SyncCheckpoint.data`, opaque to core.
public struct CloudKitGraphSyncTransport: GraphSyncTransport, Sendable {

    public let backendID: SyncBackendID
    private let database: any CloudKitDatabase

    public init(backendID: SyncBackendID, database: any CloudKitDatabase) {
        self.backendID = backendID
        self.database = database
    }

    public func push(_ batch: ChangeBatch) async throws -> PushResult {
        var savingRecords: [CloudKitRecord] = []
        var savingChangeIDs: [CloudKitRecordID: ChangeID] = [:]
        var deletingRecordIDs: [CloudKitRecordID] = []
        var deletingChangeIDs: [CloudKitRecordID: ChangeID] = [:]

        for change in batch.changes {
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
            // Transient — surface every change in the batch as retryable.
            return PushResult(
                accepted: [],
                rejected: batch.changes.map {
                    SyncRejection(changeID: $0.id, reason: .transient(error.reason))
                },
                checkpoint: nil
            )
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

        return PushResult(accepted: accepted, rejected: rejected, checkpoint: nil)
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

/// Adapter-side error surface for transient CloudKit failures (network drops, throttling).
/// Production code maps `CKError.networkFailure` / `.serviceUnavailable` / `.zoneBusy` to this.
public struct CloudKitTransportError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case networkFailure
        case serviceUnavailable
        case throttled
    }
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }

    public var reason: String {
        switch kind {
        case .networkFailure: return "network failure"
        case .serviceUnavailable: return "service unavailable"
        case .throttled: return "throttled"
        }
    }

    public static let networkFailure = CloudKitTransportError(.networkFailure)
    public static let serviceUnavailable = CloudKitTransportError(.serviceUnavailable)
    public static let throttled = CloudKitTransportError(.throttled)
}
