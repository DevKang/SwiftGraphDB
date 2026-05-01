import Foundation

/// Serialises writes around the SQLite store and the in-memory layer.
///
/// SPEC §8.1, §8.2. Writes are durable-first: SQLite commits before in-memory state changes.
/// If the in-memory update throws, the actor rebuilds from SQLite (the source of truth) before
/// returning. Tests can inject either failure via `setFailureMode(_:)`.
///
/// Reads use `snapshotTopology()` to produce an immutable view (OML-1937) that traversal can
/// walk off-actor without per-node hops.
public actor GraphActor {

    // MARK: - State

    private var indexMap: IndexMap
    private var forward: CSRAdjacency
    private var reverse: CSRAdjacency
    private var edgeLog: EdgeLog
    private var labelIndex: LabelIndex
    private var propertyIndex: PropertyIndex
    private let store: SQLiteStore
    private let nodeRepo: NodeRepository
    private let edgeRepo: EdgeRepository
    private let propertyIndexSpecs: [PropertyIndexSpec]
    private var failureMode: FailureMode = .none

    /// Test-only injection point. Production code never sets this.
    public enum FailureMode: Sendable, Equatable {
        case none
        /// The next SQLite-level write throws before any in-memory mutation runs.
        case nextSQLiteWrite
        /// The SQLite write succeeds but the in-memory update throws, forcing a rebuild.
        case nextInMemoryUpdate
    }

    // MARK: - Init

    public init(store: SQLiteStore, propertyIndexSpecs: [PropertyIndexSpec] = []) async {
        self.store = store
        self.propertyIndexSpecs = propertyIndexSpecs
        self.nodeRepo = NodeRepository(store: store)
        self.edgeRepo = EdgeRepository(store: store)
        // Empty initial state — `GraphStore.open` (OML-1938) wires this to a rebuild result.
        self.indexMap = IndexMap()
        self.forward = CSRAdjacency(nodeCount: 0, edges: [])
        self.reverse = CSRAdjacency(nodeCount: 0, edges: [])
        self.edgeLog = EdgeLog()
        self.labelIndex = LabelIndex()
        self.propertyIndex = PropertyIndex(specs: propertyIndexSpecs)
    }

    /// Hydrate state from a `RebuildFromSQLite.Result`. Used by `GraphStore.open` and by the
    /// actor's drift-recovery path.
    public func loadRebuildResult(_ result: RebuildFromSQLite.Result) {
        self.indexMap = result.indexMap
        self.forward = result.forward
        self.reverse = result.reverse
        self.labelIndex = result.labelIndex
        self.propertyIndex = result.propertyIndex
        self.edgeLog = EdgeLog()
    }

    // MARK: - Public writes

    @discardableResult
    public func addNode(label: String, properties: [String: PropertyValue]) async throws -> NodeID {
        let id = IDFactory.live.nodeID()
        let node = Node(id: id, label: label, properties: properties)

        try sqliteOrFail { try nodeRepo.insert(node) }
        do {
            try inMemoryOrFail {
                _ = self.indexMap.intern(id)
                self.labelIndex.add(id, label: label)
                self.propertyIndex.insert(node)
            }
        } catch {
            try await rebuild()
        }
        return id
    }

    @discardableResult
    public func addEdge(
        from: NodeID,
        to: NodeID,
        type: String,
        properties: [String: PropertyValue]
    ) async throws -> EdgeID {
        let edgeID = IDFactory.live.edgeID()
        let edge = Edge(id: edgeID, type: type, fromID: from, toID: to, properties: properties)

        try sqliteOrFail { try edgeRepo.insert(edge) }
        do {
            try inMemoryOrFail {
                self.edgeLog.append(.init(
                    edgeID: edgeID, fromID: from, toID: to, type: type,
                    timestamp: Date(), operation: .insert
                ))
            }
        } catch {
            try await rebuild()
        }
        return edgeID
    }

    public func updateNode(id: NodeID, properties: [String: PropertyValue]) async throws {
        // Read current state for index update.
        guard let existing = try nodeRepo.fetch(id: id) else {
            throw RepositoryError.notFound(id: id.uuidString)
        }
        try sqliteOrFail { try nodeRepo.update(id: id, properties: properties) }
        do {
            try inMemoryOrFail {
                let merged = existing.with(properties: properties)
                self.propertyIndex.update(from: existing, to: merged)
            }
        } catch {
            try await rebuild()
        }
    }

    public func updateEdge(id: EdgeID, properties: [String: PropertyValue]) async throws {
        try sqliteOrFail { try edgeRepo.update(id: id, properties: properties) }
        // No in-memory edge property cache yet; nothing to update.
    }

    public func deleteNode(id: NodeID) async throws {
        guard let existing = try nodeRepo.fetch(id: id) else { return }
        try sqliteOrFail { try nodeRepo.delete(id: id) }
        do {
            try inMemoryOrFail {
                self.labelIndex.remove(id, label: existing.label)
                self.propertyIndex.delete(existing)
                if let i = self.indexMap.internalIndex(for: id) {
                    self.indexMap.release(i)
                }
            }
        } catch {
            try await rebuild()
        }
    }

    public func deleteEdge(id: EdgeID) async throws {
        guard let existing = try edgeRepo.fetch(id: id) else { return }
        try sqliteOrFail { try edgeRepo.delete(id: id) }
        do {
            try inMemoryOrFail {
                self.edgeLog.append(.init(
                    edgeID: id, fromID: existing.fromID, toID: existing.toID,
                    type: existing.type, timestamp: Date(), operation: .delete
                ))
            }
        } catch {
            try await rebuild()
        }
    }

    // MARK: - Test seams

    public func setFailureMode(_ mode: FailureMode) {
        self.failureMode = mode
    }

    public func snapshotForTests() -> InternalSnapshot {
        InternalSnapshot(
            indexMap: indexMap, forward: forward, reverse: reverse,
            edgeLog: edgeLog, labelIndex: labelIndex
        )
    }

    public func labelIndexNodes(labeled label: String) -> Set<NodeID> {
        labelIndex.nodes(labeled: label)
    }

    public func propertyIndexNodes(
        label: String, property: String, equals value: PropertyValue
    ) -> Set<NodeID>? {
        propertyIndex.nodes(label: label, property: property, equals: value)
    }

    public var unsafeStoreForTests: SQLiteStore { store }

    public struct InternalSnapshot: Sendable {
        public let indexMap: IndexMap
        public let forward: CSRAdjacency
        public let reverse: CSRAdjacency
        public let edgeLog: EdgeLog
        public let labelIndex: LabelIndex
    }

    // MARK: - Failure injection helpers

    private func sqliteOrFail(_ body: () throws -> Void) throws {
        if failureMode == .nextSQLiteWrite {
            failureMode = .none
            throw GraphActorError.injectedSQLiteFailure
        }
        try body()
    }

    private func inMemoryOrFail(_ body: () throws -> Void) throws {
        if failureMode == .nextInMemoryUpdate {
            failureMode = .none
            throw GraphActorError.injectedInMemoryFailure
        }
        try body()
    }

    /// Rebuild in-memory state from SQLite. Called when the actor detects drift between
    /// SQLite (source of truth) and in-memory state. Public so `GraphStore.open` can also
    /// trigger an explicit rebuild after a failed snapshot load (M7).
    public func rebuild() async throws {
        let result = try RebuildFromSQLite.rebuild(
            store: store,
            propertyIndexSpecs: propertyIndexSpecs
        )
        loadRebuildResult(result)
    }
}

public enum GraphActorError: Error, Equatable {
    case injectedSQLiteFailure
    case injectedInMemoryFailure
}
