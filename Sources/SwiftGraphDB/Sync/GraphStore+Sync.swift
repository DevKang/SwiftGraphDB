import Foundation

/// Status of a sync coordinator. SPEC §12.5.
public enum SyncStatus: Sendable, Equatable {
    case idle
    case syncing(SyncBackendID)
    case offline(SyncBackendID)
    case conflict(GraphConflict)
    case error(SyncBackendID, String)
}

/// Public sync surface on `GraphStore`. SPEC §12.5.
extension GraphStore {

    /// Register a backend transport and resolver, hydrate metadata, and start the loop on
    /// demand via `syncNow`. Multiple backends can be registered simultaneously.
    public func enableSync(
        transport: GraphSyncTransport,
        resolver: GraphConflictResolver
    ) async throws {
        let coordinator = SyncCoordinator(graph: actor, transport: transport, resolver: resolver)
        let reg = await registry
        await coordinator.setOnConflict { conflict in
            reg.setStatus(.conflict(conflict))
        }
        await reg.register(
            backendID: transport.backendID,
            coordinator: coordinator
        )
    }

    /// Kick the loop once for the named backend. Throws if no such backend is registered or
    /// the loop's underlying transport throws (after the coordinator's own retry attempts).
    @discardableResult
    public func syncNow(backendID: SyncBackendID, maxBatchSize: Int = 256) async throws -> (pushed: Int, applied: Int) {
        guard let coord = await registry.coordinator(for: backendID) else {
            throw SyncRegistryError.unknownBackend(backendID.rawValue)
        }
        await registry.setStatus(.syncing(backendID))
        do {
            let result = try await coord.runOnce(maxBatchSize: maxBatchSize)
            await registry.setStatus(.idle)
            return result
        } catch {
            // Transient transport errors transition to .offline rather than .error so apps
            // can keep accepting writes; permanent errors surface for app handling.
            if isTransient(error) {
                await registry.setStatus(.offline(backendID))
            } else {
                await registry.setStatus(.error(backendID, "\(error)"))
            }
            throw error
        }
    }

    /// Detect transport-level transient errors so the registry can publish `.offline` rather
    /// than `.error`. Adapters surface transient failures via `SyncRejectionReason.transient`
    /// or by throwing a typed error containing "transient" semantics.
    private func isTransient(_ error: Error) -> Bool {
        if let coreError = error as? InMemorySyncError, coreError == .injectedTransient {
            return true
        }
        // String-match URLError-style transient cases without importing the framework here.
        let description = String(describing: error).lowercased()
        return description.contains("transient")
            || description.contains("offline")
            || description.contains("network")
    }

    /// Cancel the registration. Persisted `sync_checkpoints` rows are kept so re-enabling
    /// resumes from where it left off.
    public func disableSync(backendID: SyncBackendID) async {
        await registry.unregister(backendID)
    }

    /// Observable status stream. Multiplexes events from every registered backend.
    public var syncStatus: AsyncStream<SyncStatus> {
        get async { await registry.statusStream }
    }
}

/// Errors raised by the per-store sync registry when registering or operating on backends.
public enum SyncRegistryError: Error, Equatable {
    case unknownBackend(String)
}

/// Per-`GraphStore` actor that owns the registered coordinators and a single shared status
/// stream. We keep this hidden behind `GraphStore` so apps don't acquire it directly.
extension GraphStore {
    /// Each `GraphStore` lazily owns one `SyncRegistry` actor. The associated-object pattern
    /// keeps the registry private without changing `GraphStore`'s declared properties.
    final class SyncRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var coordinators: [SyncBackendID: SyncCoordinator] = [:]
        private var continuations: [SyncBackendID: AsyncStream<SyncStatus>.Continuation] = [:]
        private var streamContinuation: AsyncStream<SyncStatus>.Continuation?
        private var stream: AsyncStream<SyncStatus>!

        init() {
            self.stream = AsyncStream { continuation in
                self.streamContinuation = continuation
            }
        }

        var statusStream: AsyncStream<SyncStatus> { stream }

        func register(backendID: SyncBackendID, coordinator: SyncCoordinator) {
            lock.lock(); coordinators[backendID] = coordinator; lock.unlock()
        }

        func coordinator(for backendID: SyncBackendID) -> SyncCoordinator? {
            lock.lock(); defer { lock.unlock() }
            return coordinators[backendID]
        }

        func unregister(_ backendID: SyncBackendID) {
            lock.lock(); coordinators.removeValue(forKey: backendID); lock.unlock()
        }

        func setStatus(_ status: SyncStatus) {
            streamContinuation?.yield(status)
        }
    }

    /// A single registry per GraphStore. Lazy / thread-safe via Swift's let-init semantics.
    var registry: SyncRegistry {
        get async { _registry }
    }

    /// Backing storage. Stored as a let on the type via private extension below.
    private var _registry: SyncRegistry { Self.sharedRegistry(for: self) }

    nonisolated(unsafe) private static let registryTable = NSMapTable<GraphStore, SyncRegistry>(
        keyOptions: [.weakMemory], valueOptions: [.strongMemory]
    )
    nonisolated(unsafe) private static let registryTableLock = NSLock()

    private static func sharedRegistry(for store: GraphStore) -> SyncRegistry {
        registryTableLock.lock(); defer { registryTableLock.unlock() }
        if let existing = registryTable.object(forKey: store) { return existing }
        let made = SyncRegistry()
        registryTable.setObject(made, forKey: store)
        return made
    }
}
