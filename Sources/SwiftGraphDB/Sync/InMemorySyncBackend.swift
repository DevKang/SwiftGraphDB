import Foundation

/// Shared in-memory "server" for tests and SDK demos. Holds an append-only log of changes
/// accepted from any device plus per-device cursors so each transport sees only changes it
/// hasn't yet pulled. Conflict surfacing follows the protocol — the backend never resolves.
public actor InMemorySyncBackend {

    public init() {}

    private var log: [GraphChange] = []
    private var nextSequence: Int64 = 1
    private var deviceCursors: [SyncBackendID: Int] = [:]
    private var injectFailureMode: FailureMode = .none

    public enum FailureMode: Sendable, Equatable {
        case none
        case nextPushTransient
        case nextPushPermanent
        case nextPullTransient
    }

    /// Hand back a transport scoped to one device. Each transport sees a separate cursor so
    /// device A never re-pulls its own changes.
    public func transport(for deviceID: SyncBackendID) -> InMemorySyncTransport {
        InMemorySyncTransport(backend: self, backendID: deviceID)
    }

    public func setFailureMode(_ mode: FailureMode) {
        injectFailureMode = mode
    }

    public var changeCount: Int { log.count }

    fileprivate func push(_ batch: ChangeBatch, from device: SyncBackendID) throws -> PushResult {
        if injectFailureMode == .nextPushTransient {
            injectFailureMode = .none
            return PushResult(
                accepted: [],
                rejected: batch.changes.map { SyncRejection(changeID: $0.id, reason: .transient("injected")) },
                checkpoint: nil
            )
        }
        if injectFailureMode == .nextPushPermanent {
            injectFailureMode = .none
            return PushResult(
                accepted: [],
                rejected: batch.changes.map { SyncRejection(changeID: $0.id, reason: .permanent("injected")) },
                checkpoint: nil
            )
        }
        // Idempotency: skip changes whose changeID already appears in the log.
        let known = Set(log.map(\.id))
        var accepted: [ChangeID] = []
        for change in batch.changes where !known.contains(change.id) {
            log.append(change)
            accepted.append(change.id)
        }
        // Always include changes the caller already pushed before in `accepted` so the
        // caller marks them synced (idempotent re-push is a no-op).
        for change in batch.changes where known.contains(change.id) {
            accepted.append(change.id)
        }
        nextSequence = Int64(log.count) + 1
        let cursor = SyncCheckpoint(backendID: device, data: encodeCursor(log.count))
        return PushResult(accepted: accepted, rejected: [], checkpoint: cursor)
    }

    fileprivate func pull(for device: SyncBackendID, since checkpoint: SyncCheckpoint?) throws -> PullResult {
        if injectFailureMode == .nextPullTransient {
            injectFailureMode = .none
            throw InMemorySyncError.injectedTransient
        }
        let cursor = checkpoint.flatMap { decodeCursor($0.data) } ?? deviceCursors[device] ?? 0
        // Only return changes from *other* devices so a device never re-pulls its own writes.
        var taken: [GraphChange] = []
        for i in cursor..<log.count {
            let change = log[i]
            if change.actorID.uuidString != device.rawValue {
                taken.append(change)
            }
        }
        let newCursor = log.count
        deviceCursors[device] = newCursor
        return PullResult(
            changes: taken,
            checkpoint: SyncCheckpoint(backendID: device, data: encodeCursor(newCursor)),
            hasMore: false
        )
    }

    private func encodeCursor(_ value: Int) -> Data {
        var v = Int64(value).littleEndian
        return Data(bytes: &v, count: MemoryLayout<Int64>.size)
    }

    private func decodeCursor(_ data: Data) -> Int? {
        guard data.count == MemoryLayout<Int64>.size else { return nil }
        var v: Int64 = 0
        withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst, from: 0..<MemoryLayout<Int64>.size)
        }
        return Int(Int64(littleEndian: v))
    }
}

/// Failures injected by `InMemorySyncBackend` for testing transient/permanent error paths.
public enum InMemorySyncError: Error, Equatable {
    case injectedTransient
}

/// Per-device transport handed back by `InMemorySyncBackend.transport(for:)`.
public struct InMemorySyncTransport: GraphSyncTransport, Sendable {
    public let backendID: SyncBackendID
    let backend: InMemorySyncBackend

    init(backend: InMemorySyncBackend, backendID: SyncBackendID) {
        self.backend = backend
        self.backendID = backendID
    }

    public func push(_ batch: ChangeBatch) async throws -> PushResult {
        try await backend.push(batch, from: backendID)
    }

    public func pull(since checkpoint: SyncCheckpoint?) async throws -> PullResult {
        try await backend.pull(for: backendID, since: checkpoint)
    }
}
