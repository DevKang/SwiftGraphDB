import Foundation
import SwiftGraphDB

/// Adapter-side abstraction over the subset of CloudKit the transport touches. Production
/// instances wrap `CKSyncEngine`; tests use `MockCloudKitDatabase`.
///
/// Records are passed as `CloudKitRecord` value types (not `CKRecord`) so this protocol
/// compiles on platforms without CloudKit and so tests don't need CloudKit container
/// configuration. The production wrapper translates to/from `CKRecord` at its boundary.
public protocol CloudKitDatabase: Sendable {
    var zoneName: String { get }

    /// Apply a batch of record modifications + deletions. Returns the saved + deleted records
    /// the server confirmed plus any records the server flagged as conflicts.
    func modify(
        savingRecords: [CloudKitRecord],
        deletingRecordIDs: [CloudKitRecordID]
    ) async throws -> CloudKitModifyResult

    /// Fetch records changed since `serverChangeToken`.
    func fetchChanges(
        sinceServerChangeToken token: Data?
    ) async throws -> CloudKitFetchResult
}

/// Backend-specific record name. Adapter packs the entity kind + UUID into a single string so
/// CloudKit `recordName` is deterministic.
public struct CloudKitRecordID: Sendable, Hashable, Codable {
    public let recordName: String
    public init(recordName: String) { self.recordName = recordName }

    /// Construct a CloudKit record name from a graph entity reference.
    public static func make(from entity: GraphEntityRef) -> CloudKitRecordID {
        CloudKitRecordID(recordName: "\(entity.kind.rawValue):\(entity.id.uuidString)")
    }

    public var entity: GraphEntityRef? {
        let parts = recordName.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let kind = GraphEntityKind(rawValue: parts[0]),
              let id = UUID(uuidString: parts[1])
        else { return nil }
        return GraphEntityRef(kind: kind, id: id)
    }
}

/// Test-friendly record value. Holds whatever the codec emits.
public struct CloudKitRecord: Sendable, Hashable, Codable {
    public var id: CloudKitRecordID
    public var recordType: String           // "GDB_Node" or "GDB_Edge"
    public var fields: [String: Data]       // serialised payload pieces
    public var changeTag: String?           // server-assigned per-record change tag

    public init(id: CloudKitRecordID, recordType: String, fields: [String: Data], changeTag: String? = nil) {
        self.id = id
        self.recordType = recordType
        self.fields = fields
        self.changeTag = changeTag
    }
}

public struct CloudKitModifyResult: Sendable {
    public var saved: [CloudKitRecord]
    public var deleted: [CloudKitRecordID]
    public var conflicts: [(record: CloudKitRecord, serverRecord: CloudKitRecord)]
    public init(saved: [CloudKitRecord], deleted: [CloudKitRecordID], conflicts: [(CloudKitRecord, CloudKitRecord)]) {
        self.saved = saved
        self.deleted = deleted
        self.conflicts = conflicts
    }
}

public struct CloudKitFetchResult: Sendable {
    public var changedRecords: [CloudKitRecord]
    public var deletedRecordIDs: [CloudKitRecordID]
    public var serverChangeToken: Data
    public var moreComing: Bool
    public init(
        changedRecords: [CloudKitRecord],
        deletedRecordIDs: [CloudKitRecordID],
        serverChangeToken: Data,
        moreComing: Bool
    ) {
        self.changedRecords = changedRecords
        self.deletedRecordIDs = deletedRecordIDs
        self.serverChangeToken = serverChangeToken
        self.moreComing = moreComing
    }
}
