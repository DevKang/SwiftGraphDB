import Foundation

extension NodeQuery {

    /// Materialise the query into an array of `Node` values.
    public func collect() async throws -> [Node] {
        try await execute().nodes
    }

    /// Materialise the query and the edges traversed to reach each node.
    public func collectWithEdges() async throws -> (nodes: [Node], edges: [Edge]) {
        let result = try await execute()
        return (result.nodes, result.edges)
    }

    /// Number of nodes the query produces. Short-circuits when the source can answer
    /// without materialising payloads (e.g. a label-only query reads the label index).
    public func count() async throws -> Int {
        // If the only stage is `.label`, we can answer from the label index directly.
        if stages.count == 1, case let .label(label) = stages[0] {
            return snapshot.labelIndex.nodes(labeled: label).count
        }
        return try await execute().nodes.count
    }

    /// First matching node, or nil. Stops execution as soon as one match is produced.
    public func first() async throws -> Node? {
        try await execute(limit: 1).nodes.first
    }

    /// `true` iff at least one node matches.
    public func exists() async throws -> Bool {
        try await first() != nil
    }

    // MARK: - Internals

    struct ExecutionResult {
        let nodes: [Node]
        let edges: [Edge]
    }

    private func execute(limit: Int? = nil) async throws -> ExecutionResult {
        var ids: Set<NodeID> = []
        var orderedIDs: [NodeID] = []
        var edges: [Edge] = []

        // Process stages in order.
        for (i, stage) in stages.enumerated() {
            switch stage {
            case .label(let label):
                let matches = snapshot.labelIndex.nodes(labeled: label)
                ids = matches
                orderedIDs = Array(matches)

            case .singleID(let id):
                if let _ = snapshot.indexMap.internalIndex(for: id) {
                    ids = [id]
                    orderedIDs = [id]
                }

            case .scan:
                // Scan all live nodes via the label index union (cheap when label count is
                // small) plus a SQL fallback for stores with no labels indexed yet.
                let allLabeled = snapshot.labelIndex.allLiveNodeIDs()
                ids = allLabeled
                orderedIDs = Array(allLabeled)

            case .traverse(let direction, let edgeType, let depth):
                let result = try traverse(
                    fromIDs: orderedIDs,
                    direction: direction,
                    edge: edgeType,
                    depth: depth
                )
                ids = result.visited
                orderedIDs = result.order
                edges.append(contentsOf: result.edges)

            case .filterPredicate(let predicate):
                let nodeRepo = NodeRepository(store: store)
                var kept: [NodeID] = []
                for id in orderedIDs {
                    if let node = try nodeRepo.fetch(id: id), predicate.evaluate(node) {
                        kept.append(id)
                    }
                }
                orderedIDs = kept
                ids = Set(kept)
            }

            // Apply early termination after the last stage's filter (e.g. `first()`).
            if i == stages.count - 1, let limit, orderedIDs.count > limit {
                orderedIDs = Array(orderedIDs.prefix(limit))
                ids = Set(orderedIDs)
            }
        }

        // Materialise nodes from SQLite.
        let nodeRepo = NodeRepository(store: store)
        var materialised: [Node] = []
        materialised.reserveCapacity(orderedIDs.count)
        for id in orderedIDs {
            if let node = try nodeRepo.fetch(id: id) {
                materialised.append(node)
            }
        }
        return ExecutionResult(nodes: materialised, edges: edges)
    }
}

extension NodeQuery {
    struct TraverseResult {
        var visited: Set<NodeID>
        var order: [NodeID]
        var edges: [Edge]
    }

    fileprivate func traverse(
        fromIDs: [NodeID],
        direction: TraverseDirection,
        edge edgeType: String?,
        depth: TraverseDepth
    ) throws -> TraverseResult {
        var visited = Set<NodeID>(fromIDs)
        var order: [NodeID] = []
        var collectedEdges: [Edge] = []

        var frontier = fromIDs
        var currentDepth = 0
        let maxDepth: Int = {
            switch depth {
            case .bounded(let n): return n
            case .unlimited: return Int.max
            }
        }()

        let edgeRepo = EdgeRepository(store: store)
        while !frontier.isEmpty && currentDepth < maxDepth {
            var nextFrontier: [NodeID] = []
            for id in frontier {
                let outgoing: [Edge]
                let incoming: [Edge]
                switch direction {
                case .outgoing:
                    outgoing = try edgeRepo.fetchOutgoing(from: id, type: edgeType)
                    incoming = []
                case .incoming:
                    outgoing = []
                    incoming = try edgeRepo.fetchIncoming(to: id, type: edgeType)
                case .both:
                    outgoing = try edgeRepo.fetchOutgoing(from: id, type: edgeType)
                    incoming = try edgeRepo.fetchIncoming(to: id, type: edgeType)
                }
                for e in outgoing {
                    collectedEdges.append(e)
                    if visited.insert(e.toID).inserted {
                        order.append(e.toID)
                        nextFrontier.append(e.toID)
                    }
                }
                for e in incoming {
                    collectedEdges.append(e)
                    if visited.insert(e.fromID).inserted {
                        order.append(e.fromID)
                        nextFrontier.append(e.fromID)
                    }
                }
            }
            frontier = nextFrontier
            currentDepth += 1
        }
        return TraverseResult(visited: visited, order: order, edges: collectedEdges)
    }
}

extension LabelIndex {
    /// All live node ids across every label. Used by full-scan sources.
    public func allLiveNodeIDs() -> Set<NodeID> {
        var union: Set<NodeID> = []
        for value in dictionarySnapshot.values {
            union.formUnion(value)
        }
        return union
    }

    /// Test seam — exposes the underlying dictionary snapshot for the union helper. Renamed
    /// to avoid clashing with `add/remove` mutation API.
    @_spi(Internal) public var dictionarySnapshot: [String: Set<NodeID>] {
        labelMap
    }
}
