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
        // SQL-pushdown stages (v3 TEXT properties)
        case sqlWhere(key: String, op: SQLFilterOp, value: PropertyValue)
        case sqlContains(key: String, substring: String)
        case sorted(key: String, order: SortOrder)
        case limit(count: Int, offset: Int)
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

    // MARK: - SQL-pushdown filters (v3)

    /// Sort results by a property key. Pushed down to SQLite `ORDER BY json_extract(...)`.
    public func sorted(by key: String, _ order: SortOrder = .ascending) -> NodeQuery {
        appending(.sorted(key: key, order: order))
    }

    /// Limit the number of returned nodes, with optional offset for pagination.
    public func limit(_ count: Int, offset: Int = 0) -> NodeQuery {
        appending(.limit(count: count, offset: offset))
    }

    /// String-contains filter. Pushed down to SQLite `LIKE '%substring%'`.
    public func `where`(_ key: String, contains substring: String) -> NodeQuery {
        appending(.sqlContains(key: key, substring: substring))
    }

    /// Property filter pushed down to SQLite `json_extract()`. Use when you want the database
    /// engine to filter rather than materialising all nodes into Swift first.
    public func `where`(_ key: String, _ op: SQLFilterOp, _ value: PropertyValue) -> NodeQuery {
        appending(.sqlWhere(key: key, op: op, value: value))
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

/// Comparison operator for SQL-pushdown property filters.
public enum SQLFilterOp: Sendable, Equatable {
    case equals
    case notEquals
    case greaterThan
    case greaterThanOrEqual
    case lessThan
    case lessThanOrEqual
}

/// Sort order for query results.
public enum SortOrder: Sendable, Equatable {
    case ascending
    case descending
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
