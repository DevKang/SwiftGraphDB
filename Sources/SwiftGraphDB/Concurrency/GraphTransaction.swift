import Foundation

/// A user-level transaction that groups multiple write operations into a single
/// atomic SQLite transaction. In-memory state and mutation events are deferred
/// until the transaction commits successfully.
///
/// SPEC §12.8. Obtain via `GraphStore.transaction { tx in ... }`.
/// The closure receives a `GraphTransaction`; if it returns normally the
/// transaction commits. If it throws, the SQLite transaction rolls back and
/// in-memory state is untouched.
public final class GraphTransaction: @unchecked Sendable {

    // MARK: - Internal bookkeeping

    private let store: SQLiteStore
    private let nodeRepo: NodeRepository
    private let edgeRepo: EdgeRepository
    private let journal: ChangeJournalStore
    private let mintRevision: () throws -> GraphRevision
    private let graphID: () throws -> GraphID

    /// Deferred in-memory updates to apply after SQLite commit.
    struct DeferredUpdate {
        enum Kind {
            case addNode(Node)
            case addEdge(EdgeLogEntry)
            case updateNode(old: Node, new: Node)
            case deleteNode(id: NodeID, label: String, old: Node)
            case deleteEdge(id: EdgeID, entry: EdgeLogEntry)
        }
        let kind: Kind
    }

    private(set) var deferredUpdates: [DeferredUpdate] = []
    private(set) var deferredMutations: [GraphMutation] = []

    init(
        store: SQLiteStore,
        nodeRepo: NodeRepository,
        edgeRepo: EdgeRepository,
        journal: ChangeJournalStore,
        mintRevision: @escaping () throws -> GraphRevision,
        graphID: @escaping () throws -> GraphID
    ) {
        self.store = store
        self.nodeRepo = nodeRepo
        self.edgeRepo = edgeRepo
        self.journal = journal
        self.mintRevision = mintRevision
        self.graphID = graphID
    }

    // MARK: - Write operations

    /// Add a node within this transaction.
    @discardableResult
    public func addNode(label: String, properties: [String: PropertyValue] = [:]) throws -> NodeID {
        let id = IDFactory.live.nodeID()
        let revision = try mintRevision()
        let node = Node(id: id, label: label, properties: properties, revision: revision)
        let payload = try JSONEncoder().encode(GraphRecordPayload(properties: properties, label: label))
        let gid = try graphID()

        try nodeRepo.insert(node)
        try journal.append(ChangeJournalRow(
            sequence: 0,
            changeID: ChangeID(),
            graphID: gid,
            actorID: revision.actorID,
            entityKind: .node,
            entityID: id,
            operation: .upsert,
            payload: payload,
            baseRevision: nil,
            revision: revision,
            createdAt: Date()
        ))

        deferredUpdates.append(.init(kind: .addNode(node)))
        deferredMutations.append(.nodeAdded(id, label: label))
        return id
    }

    /// Add an edge within this transaction.
    @discardableResult
    public func addEdge(
        from: NodeID, to: NodeID, type: String,
        properties: [String: PropertyValue] = [:]
    ) throws -> EdgeID {
        let edgeID = IDFactory.live.edgeID()
        let revision = try mintRevision()
        let edge = Edge(id: edgeID, type: type, fromID: from, toID: to,
                        properties: properties, revision: revision)
        let payload = try JSONEncoder().encode(GraphRecordPayload(
            properties: properties, type: type, fromID: from, toID: to
        ))
        let gid = try graphID()

        try edgeRepo.insert(edge)
        try journal.append(ChangeJournalRow(
            sequence: 0,
            changeID: ChangeID(),
            graphID: gid,
            actorID: revision.actorID,
            entityKind: .edge,
            entityID: edgeID,
            operation: .upsert,
            payload: payload,
            baseRevision: nil,
            revision: revision,
            createdAt: Date()
        ))

        let entry = EdgeLogEntry(
            edgeID: edgeID, fromID: from, toID: to, type: type,
            revision: revision, operation: .upsert
        )
        deferredUpdates.append(.init(kind: .addEdge(entry)))
        deferredMutations.append(.edgeAdded(edgeID, type: type, from: from, to: to))
        return edgeID
    }

    /// Update a node's properties within this transaction.
    public func updateNode(id: NodeID, properties: [String: PropertyValue]) throws {
        guard let existing = try nodeRepo.fetch(id: id) else {
            throw RepositoryError.notFound(id: id.uuidString)
        }
        let revision = try mintRevision()
        let merged = existing.with(properties: properties)
        let payload = try JSONEncoder().encode(
            GraphRecordPayload(properties: merged.properties, label: existing.label)
        )
        let gid = try graphID()

        try nodeRepo.update(id: id, properties: properties, revision: revision)
        try journal.append(ChangeJournalRow(
            sequence: 0,
            changeID: ChangeID(),
            graphID: gid,
            actorID: revision.actorID,
            entityKind: .node,
            entityID: id,
            operation: .upsert,
            payload: payload,
            baseRevision: existing.revision,
            revision: revision,
            createdAt: Date()
        ))

        deferredUpdates.append(.init(kind: .updateNode(old: existing, new: merged)))
        deferredMutations.append(.nodeUpdated(id))
    }

    /// Update an edge's properties within this transaction.
    public func updateEdge(id: EdgeID, properties: [String: PropertyValue]) throws {
        guard let existing = try edgeRepo.fetch(id: id) else {
            throw RepositoryError.notFound(id: id.uuidString)
        }
        let revision = try mintRevision()
        let merged = existing.with(properties: properties)
        let payload = try JSONEncoder().encode(GraphRecordPayload(
            properties: merged.properties, type: existing.type,
            fromID: existing.fromID, toID: existing.toID
        ))
        let gid = try graphID()

        try edgeRepo.update(id: id, properties: properties, revision: revision)
        try journal.append(ChangeJournalRow(
            sequence: 0,
            changeID: ChangeID(),
            graphID: gid,
            actorID: revision.actorID,
            entityKind: .edge,
            entityID: id,
            operation: .upsert,
            payload: payload,
            baseRevision: existing.revision,
            revision: revision,
            createdAt: Date()
        ))

        deferredMutations.append(.edgeUpdated(id))
    }

    /// Delete a node within this transaction.
    public func deleteNode(id: NodeID) throws {
        guard let existing = try nodeRepo.fetch(id: id) else { return }
        let revision = try mintRevision()
        let gid = try graphID()

        try nodeRepo.delete(id: id, revision: revision)
        try journal.append(ChangeJournalRow(
            sequence: 0,
            changeID: ChangeID(),
            graphID: gid,
            actorID: revision.actorID,
            entityKind: .node,
            entityID: id,
            operation: .delete,
            payload: nil,
            baseRevision: existing.revision,
            revision: revision,
            createdAt: Date()
        ))

        deferredUpdates.append(.init(kind: .deleteNode(id: id, label: existing.label, old: existing)))
        deferredMutations.append(.nodeDeleted(id))
    }

    /// Delete an edge within this transaction.
    public func deleteEdge(id: EdgeID) throws {
        guard let existing = try edgeRepo.fetch(id: id) else { return }
        let revision = try mintRevision()
        let gid = try graphID()

        try edgeRepo.delete(id: id, revision: revision)
        try journal.append(ChangeJournalRow(
            sequence: 0,
            changeID: ChangeID(),
            graphID: gid,
            actorID: revision.actorID,
            entityKind: .edge,
            entityID: id,
            operation: .delete,
            payload: nil,
            baseRevision: existing.revision,
            revision: revision,
            createdAt: Date()
        ))

        let entry = EdgeLogEntry(
            edgeID: id, fromID: existing.fromID, toID: existing.toID,
            type: existing.type, revision: revision, operation: .delete
        )
        deferredUpdates.append(.init(kind: .deleteEdge(id: id, entry: entry)))
        deferredMutations.append(.edgeDeleted(id))
    }
}
