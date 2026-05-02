import Foundation
import SwiftGraphDB

/// In-memory `CloudKitDatabase` for testing the adapter without an iCloud account. Records the
/// last call's saved + deleted lists so tests can assert on the translation layer.
public actor MockCloudKitDatabase: CloudKitDatabase {
    public nonisolated let zoneName: String

    private var saveResultQueue: [CloudKitModifyResult] = []
    private var fetchResultQueue: [CloudKitFetchResult] = []
    private var queuedConflicts: [(record: CloudKitRecord, serverRecord: CloudKitRecord)] = []
    private var nextSaveError: CloudKitTransportError?
    private var nextFetchError: CloudKitTransportError?
    /// FIFO queue of errors to throw on consecutive `modify` calls. Each call consumes one entry.
    private var saveErrorQueue: [CloudKitTransportError] = []

    private(set) var lastSaveCallSavedRecords: [CloudKitRecord] = []
    private(set) var lastSaveCallDeletedIDs: [CloudKitRecordID] = []
    private(set) var saveCallSavedHistory: [[CloudKitRecord]] = []
    public var saveCallCount: Int { saveCallSavedHistory.count }

    public init(zoneName: String = SwiftGraphDBCloudKit.zoneName) {
        self.zoneName = zoneName
    }

    // MARK: Test API

    public func queueSaveResult(_ result: CloudKitModifyResult) {
        saveResultQueue.append(result)
    }

    public func queueFetch(_ result: CloudKitFetchResult) {
        fetchResultQueue.append(result)
    }

    public func queueConflict(_ pair: (record: CloudKitRecord, serverRecord: CloudKitRecord)) {
        queuedConflicts.append(pair)
    }

    public func setNextSaveError(_ error: CloudKitTransportError) {
        nextSaveError = error
    }

    /// Queue errors to throw on the next N `modify` calls. Each modify call consumes the
    /// head of the queue; once empty, modify proceeds normally.
    public func queueSaveErrors(_ errors: [CloudKitTransportError]) {
        saveErrorQueue.append(contentsOf: errors)
    }

    public func setNextFetchError(_ error: CloudKitTransportError) {
        nextFetchError = error
    }

    // MARK: CloudKitDatabase

    public func modify(
        savingRecords: [CloudKitRecord],
        deletingRecordIDs: [CloudKitRecordID]
    ) async throws -> CloudKitModifyResult {
        lastSaveCallSavedRecords = savingRecords
        lastSaveCallDeletedIDs = deletingRecordIDs
        saveCallSavedHistory.append(savingRecords)
        if !saveErrorQueue.isEmpty {
            let err = saveErrorQueue.removeFirst()
            throw err
        }
        if let err = nextSaveError {
            nextSaveError = nil
            throw err
        }
        if let queued = saveResultQueue.first {
            saveResultQueue.removeFirst()
            return queued
        }
        let conflicts = queuedConflicts
        queuedConflicts.removeAll()
        let conflictedRecordIDs = Set(conflicts.map { $0.record.id })
        let saved = savingRecords.filter { !conflictedRecordIDs.contains($0.id) }
        return CloudKitModifyResult(
            saved: saved,
            deleted: deletingRecordIDs,
            conflicts: conflicts
        )
    }

    public func fetchChanges(
        sinceServerChangeToken token: Data?
    ) async throws -> CloudKitFetchResult {
        if let err = nextFetchError {
            nextFetchError = nil
            throw err
        }
        if let queued = fetchResultQueue.first {
            fetchResultQueue.removeFirst()
            return queued
        }
        return CloudKitFetchResult(
            changedRecords: [],
            deletedRecordIDs: [],
            serverChangeToken: token ?? Data(),
            moreComing: false
        )
    }
}
