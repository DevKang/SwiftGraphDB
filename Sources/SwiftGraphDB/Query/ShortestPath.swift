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
}
