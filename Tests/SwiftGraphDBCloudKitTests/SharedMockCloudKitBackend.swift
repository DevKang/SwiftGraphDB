import Foundation
@testable import SwiftGraphDB
@testable import SwiftGraphDBCloudKit

/// Shared in-memory fake of the CloudKit private database. Multiple `CloudKitDatabase`
/// clients can share one backend so contract tests can run "two devices" without an iCloud
/// account. The model mirrors CloudKit's: an append-only log + a per-record latest version,
/// with server-issued change tokens delivered as opaque little-endian Int64 cursors.
public actor SharedMockCloudKitBackend {

    public init() {}

    private struct LogEntry: Sendable {
        let recordID: CloudKitRecordID
        let record: CloudKitRecord?     // nil → tombstone
        let serverIndex: Int            // 1-based
    }

    private var log: [LogEntry] = []

    // MARK: - CloudKit primitives

    public func modify(
        savingRecords: [CloudKitRecord],
        deletingRecordIDs: [CloudKitRecordID]
    ) -> CloudKitModifyResult {
        for record in savingRecords {
            log.append(LogEntry(recordID: record.id, record: record, serverIndex: log.count + 1))
        }
        for id in deletingRecordIDs {
            log.append(LogEntry(recordID: id, record: nil, serverIndex: log.count + 1))
        }
        return CloudKitModifyResult(saved: savingRecords, deleted: deletingRecordIDs, conflicts: [])
    }

    public func fetchChanges(
        sinceServerChangeToken token: Data?
    ) -> CloudKitFetchResult {
        let cursor = decode(token) ?? 0
        var changed: [CloudKitRecord] = []
        var deleted: [CloudKitRecordID] = []
        for entry in log where entry.serverIndex > cursor {
            if let record = entry.record {
                changed.append(record)
            } else {
                deleted.append(entry.recordID)
            }
        }
        return CloudKitFetchResult(
            changedRecords: changed,
            deletedRecordIDs: deleted,
            serverChangeToken: encode(log.count),
            moreComing: false
        )
    }

    // MARK: - Cursor encoding (opaque to core)

    private func encode(_ value: Int) -> Data {
        var v = Int64(value).littleEndian
        return Data(bytes: &v, count: MemoryLayout<Int64>.size)
    }

    private func decode(_ data: Data?) -> Int? {
        guard let data, data.count == MemoryLayout<Int64>.size else { return nil }
        var v: Int64 = 0
        withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst, from: 0..<MemoryLayout<Int64>.size)
        }
        return Int(Int64(littleEndian: v))
    }
}

/// `CloudKitDatabase` view backed by a `SharedMockCloudKitBackend`. Each "device" holds its
/// own client instance.
public struct SharedMockCloudKitClient: CloudKitDatabase, Sendable {
    public let zoneName: String
    public let backend: SharedMockCloudKitBackend

    public init(backend: SharedMockCloudKitBackend, zoneName: String = SwiftGraphDBCloudKit.zoneName) {
        self.backend = backend
        self.zoneName = zoneName
    }

    public func modify(
        savingRecords: [CloudKitRecord],
        deletingRecordIDs: [CloudKitRecordID]
    ) async throws -> CloudKitModifyResult {
        await backend.modify(savingRecords: savingRecords, deletingRecordIDs: deletingRecordIDs)
    }

    public func fetchChanges(
        sinceServerChangeToken token: Data?
    ) async throws -> CloudKitFetchResult {
        await backend.fetchChanges(sinceServerChangeToken: token)
    }
}
