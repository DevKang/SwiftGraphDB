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
    private var revisionCounter: Int64 = 0
    /// Local actor identity, hydrated lazily from `db_meta.actor_id` on first revision mint.
    private var actorIDCache: ActorID?
    /// Bounded LRU cache for decoded `[String: PropertyValue]` dictionaries. Invalidated on
    /// update / delete so reads never see stale property data.
    private var propertyCache: LRUCache<NodeID, [String: PropertyValue]>
    private var propertyCacheHits: Int = 0
    private var propertyCacheMisses: Int = 0
    /// Local graph identity, hydrated lazily from `db_meta.graph_id`. Stamped onto every
    /// `change_journal` row so adapters can attribute changes to the right store.
    private var graphIDCache: GraphID?

    private var journal: ChangeJournalStore { ChangeJournalStore(store: store) }

    private func mintRevision() throws -> GraphRevision {
        if actorIDCache == nil {
            let rows = try store.query(
                "SELECT value FROM db_meta WHERE key = ?", [.text("actor_id")]
            ) { $0.text(at: 0) }
            guard let value = rows.first.flatMap({ $0 }), let parsed = ActorID(uuidString: value) else {
                throw GraphActorError.actorIDMissing
            }
            actorIDCache = parsed
        }
        // On first call, hydrate `revisionCounter` from MAX(counter) over our own revisions
        // so that re-opening a store doesn't reset the counter back to 1.
        if revisionCounter == 0 {
            revisionCounter = try maxKnownCounter()
        }
        revisionCounter += 1
        return GraphRevision(actorID: actorIDCache!, counter: revisionCounter, wallClock: Date())
    }

    private func graphID() throws -> GraphID {
        if let cached = graphIDCache { return cached }
        let rows = try store.query(
            "SELECT value FROM db_meta WHERE key = ?", [.text("graph_id")]
        ) { $0.text(at: 0) }
        guard let value = rows.first.flatMap({ $0 }), let parsed = GraphID(uuidString: value) else {
            throw GraphActorError.actorIDMissing // re-use; missing meta is the same diagnosis
        }
        graphIDCache = parsed
        return parsed
    }

    private func maxKnownCounter() throws -> Int64 {
        guard let actor = actorIDCache else { return 0 }
        // Inspect change_journal first (highest fidelity); fall back to entity rows.
        let actorJSONFragment = "\"actorID\":\"\(actor.uuidString)\""
        let cj = try store.query(
            "SELECT revision FROM change_journal WHERE actor_id = ? ORDER BY sequence DESC LIMIT 1",
            [.text(actor.uuidString)]
        ) { $0.text(at: 0) }
        if let json = cj.first.flatMap({ $0 }),
           let data = json.data(using: .utf8),
           let r = try? JSONDecoder().decode(GraphRevision.self, from: data) {
            return r.counter
        }
        // No journal rows yet — hunt entity tables.
        var best: Int64 = 0
        for table in ["nodes", "edges"] {
            let rows = try store.query("SELECT revision FROM \(table)") { $0.text(at: 0) }
            for raw in rows where raw?.contains(actorJSONFragment) == true {
                if let json = raw, let data = json.data(using: .utf8),
                   let r = try? JSONDecoder().decode(GraphRevision.self, from: data) {
                    best = max(best, r.counter)
                }
            }
        }
        return best
    }

    /// Test-only injection point. Production code never sets this.
    public enum FailureMode: Sendable, Equatable {
        case none
        /// The next SQLite-level write throws before any in-memory mutation runs.
        case nextSQLiteWrite
        /// The SQLite write succeeds but the in-memory update throws, forcing a rebuild.
        case nextInMemoryUpdate
    }

    // MARK: - Init

    public init(
        store: SQLiteStore,
        propertyIndexSpecs: [PropertyIndexSpec] = [],
        propertyCacheCapacity: Int = 10_000
    ) async {
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
        self.propertyCache = LRUCache(capacity: max(1, propertyCacheCapacity))
    }

    /// Cached property fetch. The graph actor is the only writer; cache invalidation happens
    /// inside the write transaction so a successful read sees the same state SQLite has.
    public func cachedProperties(for id: NodeID) throws -> [String: PropertyValue]? {
        if let hit = propertyCache.get(id) {
            propertyCacheHits += 1
            return hit
        }
        propertyCacheMisses += 1
        guard let node = try nodeRepo.fetch(id: id) else { return nil }
        propertyCache.put(id, node.properties)
        return node.properties
    }

    public func clearPropertyCache() {
        propertyCache.removeAll()
        propertyCacheHits = 0
        propertyCacheMisses = 0
    }

    /// Hand the actor a memory-pressure monitor. Warning / critical events drop the property
    /// cache; critical also schedules an opportunistic compaction trigger.
    public func attachMemoryPressureMonitor(_ monitor: MemoryPressureMonitor) {
        monitor.setHandler { [weak self] level in
            guard let self else { return }
            Task { await self.handleMemoryPressure(level) }
        }
    }

    func handleMemoryPressure(_ level: MemoryPressureLevel) {
        clearPropertyCache()
        // Critical events also empty the EdgeLog (forcing the next read to merge nothing
        // and the next write to repopulate). Compaction is the natural follow-up but is
        // scheduled by callers via `triggerCompactionIfNeeded()` to keep this hook narrow.
        if level == .critical {
            edgeLog = EdgeLog()
        }
    }

    public var propertyCacheStats: (hits: Int, misses: Int) {
        (propertyCacheHits, propertyCacheMisses)
    }

    // MARK: - Sync coordinator helpers (M8)

    /// Hand the coordinator a stamped `graphID`.
    func graphIDForCoordinator() throws -> GraphID {
        try graphID()
    }

    func fetchPayloadForCoordinator(kind: ChangeJournalRow.EntityKind, id: UUID) throws -> GraphRecordPayload? {
        switch kind {
        case .node:
            guard let node = try nodeRepo.fetch(id: id) else { return nil }
            return GraphRecordPayload(properties: node.properties, label: node.label)
        case .edge:
            guard let edge = try edgeRepo.fetch(id: id) else { return nil }
            return GraphRecordPayload(
                properties: edge.properties, type: edge.type,
                fromID: edge.fromID, toID: edge.toID
            )
        }
    }

    func applyRemoteChangeForCoordinator(_ change: GraphChange) async throws {
        switch (change.entity.kind, change.operation) {
        case (.node, .upsert):
            guard let payload = change.payload, let label = payload.label else { return }
            if try nodeRepo.fetch(id: change.entity.id) != nil {
                try await self.updateNode(id: change.entity.id, properties: payload.properties)
            } else {
                let node = Node(
                    id: change.entity.id, label: label,
                    properties: payload.properties,
                    revision: change.revision
                )
                try store.transaction { _ in try nodeRepo.insert(node) }
                _ = self.indexMap.intern(change.entity.id)
                self.labelIndex.add(change.entity.id, label: label)
                self.propertyIndex.insert(node)
            }
        case (.node, .delete):
            // The remote actor's revision is what we want to stamp; for now reuse local mint
            // since the public API is symmetric.
            try await self.deleteNode(id: change.entity.id)
        case (.edge, .upsert):
            guard let payload = change.payload,
                  let type = payload.type, let from = payload.fromID, let to = payload.toID
            else { return }
            if try edgeRepo.fetch(id: change.entity.id) != nil {
                try await self.updateEdge(id: change.entity.id, properties: payload.properties)
            } else {
                let edge = Edge(
                    id: change.entity.id, type: type, fromID: from, toID: to,
                    properties: payload.properties, revision: change.revision
                )
                try store.transaction { _ in try edgeRepo.insert(edge) }
                self.edgeLog.append(.init(
                    edgeID: change.entity.id, fromID: from, toID: to, type: type,
                    revision: change.revision, operation: .upsert
                ))
            }
        case (.edge, .delete):
            try await self.deleteEdge(id: change.entity.id)
        }
    }

    func applyMergedPayloadForCoordinator(
        kind: GraphEntityKind,
        id: UUID,
        payload: GraphRecordPayload
    ) async throws {
        switch kind {
        case .node:
            try await self.updateNode(id: id, properties: payload.properties)
        case .edge:
            try await self.updateEdge(id: id, properties: payload.properties)
        }
    }

    func deleteForCoordinator(kind: GraphEntityKind, id: UUID) async throws {
        switch kind {
        case .node: try await self.deleteNode(id: id)
        case .edge: try await self.deleteEdge(id: id)
        }
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
        let revision = try mintRevision()
        let node = Node(id: id, label: label, properties: properties, revision: revision)
        let payload = try JSONEncoder().encode(GraphRecordPayload(properties: properties, label: label))
        let graphID = try graphID()

        try sqliteOrFail {
            try store.transaction { _ in
                try nodeRepo.insert(node)
                try journal.append(ChangeJournalRow(
                    sequence: 0,
                    changeID: ChangeID(),
                    graphID: graphID,
                    actorID: revision.actorID,
                    entityKind: .node,
                    entityID: id,
                    operation: .upsert,
                    payload: payload,
                    baseRevision: nil,
                    revision: revision,
                    createdAt: Date()
                ))
            }
        }
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
        let revision = try mintRevision()
        let edge = Edge(id: edgeID, type: type, fromID: from, toID: to,
                        properties: properties, revision: revision)
        let payload = try JSONEncoder().encode(GraphRecordPayload(
            properties: properties, type: type, fromID: from, toID: to
        ))
        let graphID = try graphID()

        try sqliteOrFail {
            try store.transaction { _ in
                try edgeRepo.insert(edge)
                try journal.append(ChangeJournalRow(
                    sequence: 0,
                    changeID: ChangeID(),
                    graphID: graphID,
                    actorID: revision.actorID,
                    entityKind: .edge,
                    entityID: edgeID,
                    operation: .upsert,
                    payload: payload,
                    baseRevision: nil,
                    revision: revision,
                    createdAt: Date()
                ))
            }
        }
        do {
            try inMemoryOrFail {
                self.edgeLog.append(.init(
                    edgeID: edgeID, fromID: from, toID: to, type: type,
                    revision: revision,
                    operation: .upsert
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
        let revision = try mintRevision()
        let merged = existing.with(properties: properties).properties
        let payload = try JSONEncoder().encode(GraphRecordPayload(properties: merged, label: existing.label))
        let graphID = try graphID()
        try sqliteOrFail {
            try store.transaction { _ in
                try nodeRepo.update(id: id, properties: properties, revision: revision)
                try journal.append(ChangeJournalRow(
                    sequence: 0,
                    changeID: ChangeID(),
                    graphID: graphID,
                    actorID: revision.actorID,
                    entityKind: .node,
                    entityID: id,
                    operation: .upsert,
                    payload: payload,
                    baseRevision: existing.revision,
                    revision: revision,
                    createdAt: Date()
                ))
            }
        }
        do {
            try inMemoryOrFail {
                let merged = existing.with(properties: properties)
                self.propertyIndex.update(from: existing, to: merged)
                self.propertyCache.remove(existing.id)
            }
        } catch {
            try await rebuild()
        }
    }

    public func updateEdge(id: EdgeID, properties: [String: PropertyValue]) async throws {
        guard let existing = try edgeRepo.fetch(id: id) else {
            throw RepositoryError.notFound(id: id.uuidString)
        }
        let revision = try mintRevision()
        let merged = existing.with(properties: properties).properties
        let payload = try JSONEncoder().encode(GraphRecordPayload(
            properties: merged, type: existing.type,
            fromID: existing.fromID, toID: existing.toID
        ))
        let graphID = try graphID()
        try sqliteOrFail {
            try store.transaction { _ in
                try edgeRepo.update(id: id, properties: properties, revision: revision)
                try journal.append(ChangeJournalRow(
                    sequence: 0,
                    changeID: ChangeID(),
                    graphID: graphID,
                    actorID: revision.actorID,
                    entityKind: .edge,
                    entityID: id,
                    operation: .upsert,
                    payload: payload,
                    baseRevision: existing.revision,
                    revision: revision,
                    createdAt: Date()
                ))
            }
        }
    }

    public func deleteNode(id: NodeID) async throws {
        guard let existing = try nodeRepo.fetch(id: id) else { return }
        let revision = try mintRevision()
        let graphID = try graphID()
        try sqliteOrFail {
            try store.transaction { _ in
                try nodeRepo.delete(id: id, revision: revision)
                try journal.append(ChangeJournalRow(
                    sequence: 0,
                    changeID: ChangeID(),
                    graphID: graphID,
                    actorID: revision.actorID,
                    entityKind: .node,
                    entityID: id,
                    operation: .delete,
                    payload: nil,
                    baseRevision: existing.revision,
                    revision: revision,
                    createdAt: Date()
                ))
            }
        }
        do {
            try inMemoryOrFail {
                self.labelIndex.remove(id, label: existing.label)
                self.propertyIndex.delete(existing)
                self.propertyCache.remove(id)
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
        let revision = try mintRevision()
        let graphID = try graphID()
        try sqliteOrFail {
            try store.transaction { _ in
                try edgeRepo.delete(id: id, revision: revision)
                try journal.append(ChangeJournalRow(
                    sequence: 0,
                    changeID: ChangeID(),
                    graphID: graphID,
                    actorID: revision.actorID,
                    entityKind: .edge,
                    entityID: id,
                    operation: .delete,
                    payload: nil,
                    baseRevision: existing.revision,
                    revision: revision,
                    createdAt: Date()
                ))
            }
        }
        do {
            try inMemoryOrFail {
                self.edgeLog.append(.init(
                    edgeID: id, fromID: existing.fromID, toID: existing.toID,
                    type: existing.type,
                    revision: revision,
                    operation: .delete
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

    public var propertyIndexCopy: PropertyIndex { propertyIndex }

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

/// Errors thrown by `GraphActor` for invariant violations the storage layer cannot recover from.
public enum GraphActorError: Error, Equatable {
    case injectedSQLiteFailure
    case injectedInMemoryFailure
    /// `db_meta.actor_id` was missing when the actor tried to mint a revision. Migration #2
    /// always stamps it; reaching this means migrations weren't run.
    case actorIDMissing
}
