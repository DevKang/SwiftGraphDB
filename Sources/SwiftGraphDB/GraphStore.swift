import Foundation

/// The user-facing entry point.
///
/// SPEC §12.1. `GraphStore` owns the `GraphActor` and exposes a small write surface plus
/// `snapshotTopology()` for read-time traversal. Concurrency is whatever the actor offers —
/// multiple readers via snapshot, single-writer through the actor.
public final class GraphStore: Sendable {

    // MARK: - Options

    /// Open-time configuration. Keeps the public init small while leaving room for
    /// PRAGMA overrides, declared property indexes, and (eventually) launch-snapshot policy.
    public struct Options: Sendable {
        public var sqlite: SQLiteConfiguration
        public var propertyIndexSpecs: [PropertyIndexSpec]
        /// Override the Application Support directory used by `open(named:)`. Tests inject a
        /// temp directory so they don't pollute the user's real Application Support.
        public var applicationSupportRoot: URL?

        public init(
            sqlite: SQLiteConfiguration = .default,
            propertyIndexSpecs: [PropertyIndexSpec] = [],
            applicationSupportRoot: URL? = nil
        ) {
            self.sqlite = sqlite
            self.propertyIndexSpecs = propertyIndexSpecs
            self.applicationSupportRoot = applicationSupportRoot
        }
    }

    // MARK: - State

    /// The graph actor. `internal` so M8's `SyncCoordinator` can hand it to the resolver/loop;
    /// app code interacts via `addNode` / `enableSync` / etc.
    let actor: GraphActor

    private init(actor: GraphActor) {
        self.actor = actor
    }

    // MARK: - Open

    /// Open or create a graph at `Application Support/<name>/graph.sqlite`.
    public static func open(named name: String, options: Options = Options()) async throws -> GraphStore {
        let url = try resolveURL(named: name, options: options)
        return try await open(at: url, options: options)
    }

    /// Open or create a graph at an arbitrary URL. Parent directory is created if missing.
    public static func open(at url: URL, options: Options = Options()) async throws -> GraphStore {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let store = try SQLiteStore(at: url, configuration: options.sqlite)
        return try await openExistingStore(store: store, options: options)
    }

    /// Open an in-memory graph. No file is created.
    public static func openInMemory(options: Options = Options()) async throws -> GraphStore {
        let store = try SQLiteStore.openInMemory(configuration: options.sqlite)
        return try await openExistingStore(store: store, options: options)
    }

    /// Wrap an already-open `SQLiteStore`. Used by tests that want to seed the store before
    /// the rebuild runs.
    public static func openExistingStore(store: SQLiteStore, options: Options = Options()) async throws -> GraphStore {
        try MigrationRunner.runDefault(on: store)
        let actor = await GraphActor(store: store, propertyIndexSpecs: options.propertyIndexSpecs)
        let result = try RebuildFromSQLite.rebuild(
            store: store,
            propertyIndexSpecs: options.propertyIndexSpecs
        )
        await actor.loadRebuildResult(result)
        return GraphStore(actor: actor)
    }

    // MARK: - Writes (delegate to actor)

    @discardableResult
    public func addNode(label: String, properties: [String: PropertyValue] = [:]) async throws -> NodeID {
        try await actor.addNode(label: label, properties: properties)
    }

    @discardableResult
    public func addEdge(
        from: NodeID, to: NodeID, type: String,
        properties: [String: PropertyValue] = [:]
    ) async throws -> EdgeID {
        try await actor.addEdge(from: from, to: to, type: type, properties: properties)
    }

    public func updateNode(id: NodeID, properties: [String: PropertyValue]) async throws {
        try await actor.updateNode(id: id, properties: properties)
    }

    public func deleteNode(id: NodeID) async throws {
        try await actor.deleteNode(id: id)
    }

    public func updateEdge(id: EdgeID, properties: [String: PropertyValue]) async throws {
        try await actor.updateEdge(id: id, properties: properties)
    }

    public func deleteEdge(id: EdgeID) async throws {
        try await actor.deleteEdge(id: id)
    }

    /// Bulk-insert nodes and edges in a single SQLite transaction.
    /// In-memory state is rebuilt after the import completes. SPEC §5.5.
    @discardableResult
    public func bulkInsert(_ body: @Sendable (BulkImporter.Batch) throws -> Void) async throws -> BulkImporter.Summary {
        try await actor.bulkInsert(body)
    }

    // MARK: - Change observation

    /// Returns an `AsyncStream` of mutation events emitted by this store.
    /// Each call creates an independent subscriber; drop the returned stream to stop receiving.
    /// SPEC §12.6.
    public func changes() async -> AsyncStream<GraphMutation> {
        let (stream, _) = await actor.observeMutations()
        return stream
    }

    // MARK: - Edge reads

    /// Fetch a single edge by ID, or `nil` if it doesn't exist (or is deleted).
    public func edge(id: EdgeID) async throws -> Edge? {
        let store = await actor.unsafeStoreForTests
        return try EdgeRepository(store: store).fetch(id: id)
    }

    /// All outgoing edges from the given node. Optionally filtered by edge `type`.
    public func edges(from nodeID: NodeID, type: String? = nil) async throws -> [Edge] {
        let store = await actor.unsafeStoreForTests
        return try EdgeRepository(store: store).fetchOutgoing(from: nodeID, type: type)
    }

    /// All incoming edges to the given node. Optionally filtered by edge `type`.
    public func edges(to nodeID: NodeID, type: String? = nil) async throws -> [Edge] {
        let store = await actor.unsafeStoreForTests
        return try EdgeRepository(store: store).fetchIncoming(to: nodeID, type: type)
    }

    /// All edges of a given type across the entire graph.
    public func edges(ofType type: String) async throws -> [Edge] {
        let store = await actor.unsafeStoreForTests
        return try EdgeRepository(store: store).fetchAll(type: type)
    }

    // MARK: - Reads

    /// Capture an immutable, off-actor snapshot of the in-memory topology. Walked off-actor by
    /// the M5 query engine.
    public func snapshotTopology() async -> TopologySnapshot {
        await actor.snapshotTopology()
    }

    public func close() async {
        // SQLiteStore deinits when the actor releases its reference; making this async keeps
        // the door open for explicit teardown in M6/M7 (e.g. flushing a launch snapshot).
    }

    // MARK: - Test seams

    public func graphIDForTests() async throws -> String {
        let store = await actor.unsafeStoreForTests
        let rows = try store.query(
            "SELECT value FROM db_meta WHERE key = ?",
            [.text("graph_id")]
        ) { $0.text(at: 0) }
        guard let value = rows.first.flatMap({ $0 }) else {
            throw RepositoryError.malformedRow
        }
        return value
    }

    public func propertyIndexNodes(
        label: String, property: String, equals value: PropertyValue
    ) async -> Set<NodeID>? {
        await actor.propertyIndexNodes(label: label, property: property, equals: value)
    }

    /// Internal accessor used by the query layer to fetch properties. Not for app use.
    @_spi(Internal) public var storeForQueriesUnsafe: SQLiteStore {
        get async { await actor.unsafeStoreForTests }
    }

    @_spi(Internal) public var propertyIndexForQueriesUnsafe: PropertyIndex {
        get async { await actor.propertyIndexCopy }
    }

    // MARK: - URL resolution

    private static func resolveURL(named name: String, options: Options) throws -> URL {
        let root: URL
        if let injected = options.applicationSupportRoot {
            root = injected
        } else {
            root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let dir = root.appendingPathComponent(name, isDirectory: true)
        return dir.appendingPathComponent("graph.sqlite")
    }
}
