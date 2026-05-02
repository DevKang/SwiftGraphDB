import Foundation

/// Lazy node-query pipeline. Source operations build the initial value; filter / traverse
/// transform it; collect terminates.
///
/// SPEC §7. The pipeline holds an immutable `TopologySnapshot` (M4) plus a reference to the
/// `SQLiteStore` for property fallback. Stages are stored as plain enum values and evaluated
/// lazily inside `collect()` (and friends).
public struct NodeQuery: Sendable {

    let snapshot: TopologySnapshot
    let store: SQLiteStore
    let propertyIndex: PropertyIndex
    let stages: [Stage]

    enum Stage: Sendable {
        case label(String)
        case singleID(NodeID)
        case scan
        case traverse(direction: TraverseDirection, edge: String?, maxDepth: TraverseDepth)
        case filterPredicate(NodeFilter)
    }

    /// Append a stage and return a new query (value-type composition).
    func appending(_ stage: Stage) -> NodeQuery {
        NodeQuery(
            snapshot: snapshot,
            store: store,
            propertyIndex: propertyIndex,
            stages: stages + [stage]
        )
    }
}

/// Direction of a traversal step.
public enum TraverseDirection: Sendable, Equatable {
    case outgoing
    case incoming
    case both
}

/// Maximum BFS depth; `.unlimited` walks the connected subgraph.
public enum TraverseDepth: Sendable, Equatable {
    case bounded(Int)
    case unlimited
}
