import Foundation

/// Telemetry events emitted by the snapshot lifecycle controller. App developers can observe
/// these via `SnapshotLifecycle.events` to debug mysterious slow launches without us shipping
/// debug code.
public enum SnapshotEvent: Sendable, Equatable {
    case loaded
    case discardedCorrupt(reason: String)
    case rebuilt
    case written
    case skipped
}

/// Snapshot policy. `auto` is the default; `disabled` skips read and write entirely.
public enum SnapshotPolicy: Sendable, Equatable {
    case auto
    case disabled
}

/// Lifecycle controller — the single place that knows when to read, when to throw away, and
/// when to write a snapshot. Owns no state of its own beyond the on-disk file plus the
/// observable event stream.
public final class SnapshotLifecycle: @unchecked Sendable {

    public let url: URL
    public let policy: SnapshotPolicy
    private let continuation: AsyncStream<SnapshotEvent>.Continuation
    public let events: AsyncStream<SnapshotEvent>

    public init(url: URL, policy: SnapshotPolicy = .auto) {
        self.url = url
        self.policy = policy
        var c: AsyncStream<SnapshotEvent>.Continuation!
        self.events = AsyncStream { continuation in
            c = continuation
        }
        self.continuation = c
    }

    /// Try to load a snapshot. Returns nil if the policy is `.disabled`, the file is missing,
    /// or any validation step fails. On a corrupt / mismatched file the lifecycle deletes the
    /// snapshot artefacts so the next compaction starts fresh.
    public func tryLoad(expectedSchemaVersion: Int32) -> SnapshotPayload? {
        guard policy == .auto else {
            continuation.yield(.skipped)
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let payload = try SnapshotReader.read(at: url, expectedSchemaVersion: expectedSchemaVersion)
            continuation.yield(.loaded)
            return payload
        } catch {
            continuation.yield(.discardedCorrupt(reason: "\(error)"))
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("tmp"))
            try? FileManager.default.removeItem(at: url.appendingPathExtension("meta"))
            continuation.yield(.rebuilt)
            return nil
        }
    }

    /// Persist a fresh snapshot. Skipped if the policy is `.disabled`.
    public func write(_ payload: SnapshotPayload) throws {
        guard policy == .auto else {
            continuation.yield(.skipped)
            return
        }
        try SnapshotWriter.write(payload, to: url)
        continuation.yield(.written)
    }

    deinit { continuation.finish() }
}
