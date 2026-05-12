import Foundation

/// A path through the graph: ordered nodes start→end and the edges that connect them.
public struct GraphPath: Sendable, Equatable {
    public let nodes: [Node]
    public let edges: [Edge]
    public init(nodes: [Node], edges: [Edge]) {
        self.nodes = nodes
        self.edges = edges
    }
    public var length: Int { edges.count }
}

extension GraphStore {

    /// Unweighted shortest path via BFS. Returns `nil` if no path exists.
    /// Tiebreak: when multiple paths share the shortest length, the path explored first is
    /// returned (insertion-order BFS over outgoing adjacency).
    public func shortestPath(
        from: NodeID,
        to: NodeID,
        via edgeType: String? = nil
    ) async throws -> GraphPath? {
        let nodeRepo = NodeRepository(store: await storeForQueriesUnsafe)
        let edgeRepo = EdgeRepository(store: await storeForQueriesUnsafe)

        // Self-path returns a length-0 path of one node.
        if from == to {
            guard let node = try nodeRepo.fetch(id: from) else { return nil }
            return GraphPath(nodes: [node], edges: [])
        }

        // Standard BFS, recording predecessor + edge per discovered node.
        var visited: Set<NodeID> = [from]
        var predecessor: [NodeID: (NodeID, Edge)] = [:]
        var frontier: [NodeID] = [from]
        var found = false

        outer: while !frontier.isEmpty {
            var next: [NodeID] = []
            for current in frontier {
                let outgoing = try edgeRepo.fetchOutgoing(from: current, type: edgeType)
                for edge in outgoing where !visited.contains(edge.toID) {
                    visited.insert(edge.toID)
                    predecessor[edge.toID] = (current, edge)
                    if edge.toID == to {
                        found = true
                        break outer
                    }
                    next.append(edge.toID)
                }
            }
            frontier = next
        }

        guard found else { return nil }

        // Walk predecessors back from `to` to `from`.
        var nodeIDs: [NodeID] = [to]
        var pathEdges: [Edge] = []
        var cursor = to
        while cursor != from {
            guard let (prev, edge) = predecessor[cursor] else { return nil }
            pathEdges.append(edge)
            nodeIDs.append(prev)
            cursor = prev
        }
        nodeIDs.reverse()
        pathEdges.reverse()

        var nodes: [Node] = []
        nodes.reserveCapacity(nodeIDs.count)
        for id in nodeIDs {
            guard let node = try nodeRepo.fetch(id: id) else { return nil }
            nodes.append(node)
        }
        return GraphPath(nodes: nodes, edges: pathEdges)
    }

    /// All simple paths (no repeated nodes) from `from` to `to`, up to `maxDepth` edges.
    /// Uses DFS with backtracking. SPEC §7.3.
    public func allPaths(
        from: NodeID,
        to: NodeID,
        maxDepth: Int,
        via edgeType: String? = nil
    ) async throws -> [GraphPath] {
        let nodeRepo = NodeRepository(store: await storeForQueriesUnsafe)
        let edgeRepo = EdgeRepository(store: await storeForQueriesUnsafe)

        guard try nodeRepo.fetch(id: from) != nil else { return [] }
        guard try nodeRepo.fetch(id: to) != nil else { return [] }

        var results: [([NodeID], [Edge])] = []
        var visited: Set<NodeID> = [from]
        var pathNodes: [NodeID] = [from]
        var pathEdges: [Edge] = []

        func dfs(_ current: NodeID, depth: Int) throws {
            if current == to {
                results.append((pathNodes, pathEdges))
                return
            }
            guard depth < maxDepth else { return }

            let outgoing = try edgeRepo.fetchOutgoing(from: current, type: edgeType)
            for edge in outgoing where !visited.contains(edge.toID) {
                visited.insert(edge.toID)
                pathNodes.append(edge.toID)
                pathEdges.append(edge)

                try dfs(edge.toID, depth: depth + 1)

                pathNodes.removeLast()
                pathEdges.removeLast()
                visited.remove(edge.toID)
            }
        }

        try dfs(from, depth: 0)

        // Materialise Node objects for each path.
        var nodeCache: [NodeID: Node] = [:]
        return try results.compactMap { (ids, edges) -> GraphPath? in
            var nodes: [Node] = []
            for id in ids {
                if let cached = nodeCache[id] {
                    nodes.append(cached)
                } else if let node = try nodeRepo.fetch(id: id) {
                    nodeCache[id] = node
                    nodes.append(node)
                } else {
                    return nil
                }
            }
            return GraphPath(nodes: nodes, edges: edges)
        }
    }
}
