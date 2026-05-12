import Foundation

extension GraphStore {
    /// All live nodes carrying `label`. Backed by the in-memory label index (O(1)).
    public func nodes(labeled label: String) async -> NodeQuery {
        let snapshot = await snapshotTopology()
        let store = await storeForQueriesUnsafe
        let index = await propertyIndexForQueriesUnsafe
        return NodeQuery(
            snapshot: snapshot,
            store: store,
            propertyIndex: index,
            stages: [.label(label)]
        )
    }

    /// Single-node lookup by id. The query collects to `[node]` if live, `[]` otherwise.
    public func node(id: NodeID) async -> NodeQuery {
        let snapshot = await snapshotTopology()
        let store = await storeForQueriesUnsafe
        let index = await propertyIndexForQueriesUnsafe
        return NodeQuery(
            snapshot: snapshot,
            store: store,
            propertyIndex: index,
            stages: [.singleID(id)]
        )
    }

    /// Predicate source — scans every live node. Use `nodes(labeled:)` first when possible
    /// since the label index avoids the SQL scan.
    public func nodes(where key: String, equals value: PropertyValue) async -> NodeQuery {
        await scannedQuery(filter: NodeFilter { $0.properties[key] == value })
    }

    public func nodes(where key: String, greaterThan value: PropertyValue) async -> NodeQuery {
        await scannedQuery(filter: NodeFilter {
            guard let v = $0.properties[key] else { return false }
            return Self.compare(v, value) == .greater
        })
    }

    public func nodes(where key: String, lessThan value: PropertyValue) async -> NodeQuery {
        await scannedQuery(filter: NodeFilter {
            guard let v = $0.properties[key] else { return false }
            return Self.compare(v, value) == .less
        })
    }

    public func nodes(where key: String, in values: [PropertyValue]) async -> NodeQuery {
        let set = Set(values)
        return await scannedQuery(filter: NodeFilter {
            guard let v = $0.properties[key] else { return false }
            return set.contains(v)
        })
    }

    private func scannedQuery(filter: NodeFilter) async -> NodeQuery {
        let snapshot = await snapshotTopology()
        let store = await storeForQueriesUnsafe
        let index = await propertyIndexForQueriesUnsafe
        return NodeQuery(
            snapshot: snapshot,
            store: store,
            propertyIndex: index,
            stages: [.scan, .filterPredicate(filter)]
        )
    }

    // MARK: - Edge queries

    /// Query builder for edges of a given type. Supports `.where()`, `.sorted()`, `.limit()` chaining.
    public func edgeQuery(type: String) async -> EdgeQuery {
        let store = await storeForQueriesUnsafe
        return EdgeQuery(store: store, stages: [.ofType(type)])
    }

    /// Query builder for edges originating from a given node.
    public func edgeQuery(from nodeID: NodeID) async -> EdgeQuery {
        let store = await storeForQueriesUnsafe
        return EdgeQuery(store: store, stages: [.fromNode(nodeID)])
    }

    /// Query builder for edges targeting a given node.
    public func edgeQuery(to nodeID: NodeID) async -> EdgeQuery {
        let store = await storeForQueriesUnsafe
        return EdgeQuery(store: store, stages: [.toNode(nodeID)])
    }

    /// Cross-type comparable for `PropertyValue` predicates. Same-type comparisons use the
    /// natural order; cross-type returns `.incomparable` (filters reject the row).
    enum CompareResult { case less, equal, greater, incomparable }

    static func compare(_ a: PropertyValue, _ b: PropertyValue) -> CompareResult {
        switch (a, b) {
        case (.int(let x), .int(let y)):       return x == y ? .equal : (x < y ? .less : .greater)
        case (.double(let x), .double(let y)): return x == y ? .equal : (x < y ? .less : .greater)
        case (.string(let x), .string(let y)): return x == y ? .equal : (x < y ? .less : .greater)
        case (.bool(let x), .bool(let y)):     return x == y ? .equal : (x ? .greater : .less)
        case (.date(let x), .date(let y)):     return x == y ? .equal : (x < y ? .less : .greater)
        default:                                return .incomparable
        }
    }
}
