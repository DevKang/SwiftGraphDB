import Foundation

/// Reconstructs the in-memory layer (`IndexMap`, forward+reverse `CSRAdjacency`, `LabelIndex`,
/// optional `PropertyIndex`) from the durable SQLite store.
///
/// SPEC §4.1: in-memory state is always rebuildable from SQLite. This is the function that
/// makes the invariant true. It is invoked on every cold open until M7 introduces the launch
/// snapshot accelerator, and again whenever the graph actor detects in-memory drift relative
/// to SQLite (OML-1936 rollback path).
///
/// Memory: rows stream via `SQLiteStore.forEach` rather than `query` so a 100K-node store
/// doesn't briefly hold 100K decoded `Node` values on top of the in-memory layer being built.
public enum RebuildFromSQLite {

    public struct Result: Sendable {
        public var indexMap: IndexMap
        public var forward: CSRAdjacency
        public var reverse: CSRAdjacency
        public var labelIndex: LabelIndex
        public var propertyIndex: PropertyIndex
    }

    public enum ProgressEvent: Sendable {
        case nodes(processed: Int)
        case edges(processed: Int)
    }

    public struct Progress: Sendable {
        public let reportEvery: Int
        public let handler: @Sendable (ProgressEvent) -> Void

        public init(reportEvery: Int = 1_000, handler: @escaping @Sendable (ProgressEvent) -> Void) {
            self.reportEvery = max(1, reportEvery)
            self.handler = handler
        }
    }

    public static func rebuild(
        store: SQLiteStore,
        propertyIndexSpecs: [PropertyIndexSpec],
        progress: Progress? = nil
    ) throws -> Result {
        var indexMap = IndexMap()
        var labelIndex = LabelIndex()
        var propertyIndex = PropertyIndex(specs: propertyIndexSpecs)

        // Pass 1: stream nodes. Intern, populate label + property indexes.
        var nodesProcessed = 0
        try store.forEach(
            """
            SELECT id, label, properties
            FROM nodes
            WHERE is_deleted = 0
            """
        ) { row in
            guard
                let idText = row.text(at: 0),
                let id = UUID(uuidString: idText),
                let label = row.text(at: 1),
                let blob = row.blob(at: 2)
            else {
                throw RepositoryError.malformedRow
            }
            _ = indexMap.intern(id)
            labelIndex.add(id, label: label)
            // Decoding properties is required only when at least one property index covers this
            // label — small optimisation that matters at 100K-row scale.
            if !propertyIndexSpecs.isEmpty,
               propertyIndexSpecs.contains(where: { $0.label == label }) {
                let properties = try PropertyCoding.decode(blob)
                let node = Node(id: id, label: label, properties: properties)
                propertyIndex.insert(node)
            }
            nodesProcessed += 1
            if let progress, nodesProcessed % progress.reportEvery == 0 {
                progress.handler(.nodes(processed: nodesProcessed))
            }
        }

        // Pass 2: stream edges into bucketed (from, EdgeRecord) lists per direction.
        var forwardFlat: [(from: Int, EdgeRecord)] = []
        var reverseFlat: [(from: Int, EdgeRecord)] = []
        forwardFlat.reserveCapacity(nodesProcessed * 2) // generous; avoids many regrowths
        reverseFlat.reserveCapacity(nodesProcessed * 2)

        var edgesProcessed = 0
        try store.forEach(
            """
            SELECT id, type, from_id, to_id
            FROM edges
            WHERE is_deleted = 0
            """
        ) { row in
            guard
                let edgeIDText = row.text(at: 0), let edgeID = UUID(uuidString: edgeIDText),
                let type = row.text(at: 1),
                let fromText = row.text(at: 2), let fromID = UUID(uuidString: fromText),
                let toText = row.text(at: 3), let toID = UUID(uuidString: toText)
            else {
                throw RepositoryError.malformedRow
            }
            // Skip dangling edges whose endpoints aren't visible (e.g. soft-deleted target).
            guard
                let fromIndex = indexMap.internalIndex(for: fromID),
                let toIndex = indexMap.internalIndex(for: toID)
            else { return }

            forwardFlat.append((
                fromIndex,
                EdgeRecord(toID: toID, edgeID: edgeID, type: type)
            ))
            reverseFlat.append((
                toIndex,
                EdgeRecord(toID: fromID, edgeID: edgeID, type: type)
            ))

            edgesProcessed += 1
            if let progress, edgesProcessed % progress.reportEvery == 0 {
                progress.handler(.edges(processed: edgesProcessed))
            }
        }

        let nodeCount = indexMap.countIncludingFreed
        let forward = CSRAdjacency(nodeCount: nodeCount, edges: forwardFlat)
        let reverse = CSRAdjacency(nodeCount: nodeCount, edges: reverseFlat)

        return Result(
            indexMap: indexMap,
            forward: forward,
            reverse: reverse,
            labelIndex: labelIndex,
            propertyIndex: propertyIndex
        )
    }
}
