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

    // MARK: - Filter operations (SPEC §7)

    /// Equality filter on a property.
    public func `where`(_ key: String, equals value: PropertyValue) -> NodeQuery {
        appending(.filterPredicate(NodeFilter { $0.properties[key] == value }))
    }

    public func `where`(_ key: String, greaterThan value: PropertyValue) -> NodeQuery {
        appending(.filterPredicate(NodeFilter {
            guard let v = $0.properties[key] else { return false }
            return GraphStore.compare(v, value) == .greater
        }))
    }

    public func `where`(_ key: String, lessThan value: PropertyValue) -> NodeQuery {
        appending(.filterPredicate(NodeFilter {
            guard let v = $0.properties[key] else { return false }
            return GraphStore.compare(v, value) == .less
        }))
    }

    public func `where`(_ key: String, in values: [PropertyValue]) -> NodeQuery {
        let set = Set(values)
        return appending(.filterPredicate(NodeFilter {
            guard let v = $0.properties[key] else { return false }
            return set.contains(v)
        }))
    }

    /// Escape-hatch predicate. Disables index optimisation; the executor materialises every
    /// candidate node and runs the closure.
    public func `where`(_ predicate: @escaping @Sendable (Node) -> Bool) -> NodeQuery {
        appending(.filterPredicate(NodeFilter(predicate)))
    }

    // MARK: - Traversal (SPEC §7.4)

    /// BFS over `direction`, optionally filtered by edge `type`. Default `maxDepth = 1`.
    public func traverse(
        _ direction: TraverseDirection,
        edge: String? = nil,
        maxDepth: TraverseDepth = .bounded(1)
    ) -> NodeQuery {
        appending(.traverse(direction: direction, edge: edge, maxDepth: maxDepth))
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
