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

    private func execute(limit externalLimit: Int? = nil) async throws -> ExecutionResult {
        // Try the SQL-pushdown fast path: source (.label/.scan) followed only by SQL-native
        // stages (.sqlWhere, .sqlContains, .sorted, .limit). If there are traverse or
        // filterPredicate stages mixed in, fall back to the legacy per-stage path.
        if let result = try sqlPushdownPath(externalLimit: externalLimit) {
            return result
        }
        return try legacyPath(externalLimit: externalLimit)
    }

    // MARK: SQL-pushdown fast path

    private func sqlPushdownPath(externalLimit: Int?) throws -> ExecutionResult? {
        guard !stages.isEmpty else { return nil }
        let first = stages[0]
        // Source must be .label or .scan
        let labelFilter: String?
        switch first {
        case .label(let l): labelFilter = l
        case .scan:         labelFilter = nil
        case .singleID:     return nil   // single-ID never needs SQL pushdown
        default:            return nil
        }
        // All remaining stages must be SQL-pushable
        let rest = Array(stages.dropFirst())
        for stage in rest {
            switch stage {
            case .sqlWhere, .sqlContains, .sorted, .limit: continue
            default: return nil
            }
        }
        let (sql, bindings) = buildSQLQuery(label: labelFilter, sqlStages: rest, externalLimit: externalLimit)
        let nodes = try store.query(sql, bindings) { try NodeRepository.decodeRow($0) }
        return ExecutionResult(nodes: nodes, edges: [])
    }

    private func buildSQLQuery(
        label: String?,
        sqlStages: [Stage],
        externalLimit: Int?
    ) -> (String, [SQLValue]) {
        var clauses: [String] = ["is_deleted = 0"]
        var bindings: [SQLValue] = []
        var orderBy: String?
        var limitClause: String?

        if let label {
            clauses.append("label = ?")
            bindings.append(.text(label))
        }

        for stage in sqlStages {
            switch stage {
            case .sqlWhere(let key, let op, let value):
                let safeKey = sanitizeJSONKey(key)
                let opStr = sqlOpString(op)
                let (typeTag, sqlVal) = sqlValueComponents(for: value)
                clauses.append("json_extract(properties, '$.\(safeKey).value') \(opStr) ?")
                bindings.append(sqlVal)
                clauses.append("json_extract(properties, '$.\(safeKey).type') = ?")
                bindings.append(.text(typeTag))

            case .sqlContains(let key, let substring):
                let safeKey = sanitizeJSONKey(key)
                clauses.append("json_extract(properties, '$.\(safeKey).value') LIKE ? ESCAPE '\\'")
                let escaped = substring
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                bindings.append(.text("%\(escaped)%"))
                clauses.append("json_extract(properties, '$.\(safeKey).type') = 'string'")

            case .sorted(let key, let order):
                let safeKey = sanitizeJSONKey(key)
                let dir = order == .ascending ? "ASC" : "DESC"
                orderBy = "ORDER BY json_extract(properties, '$.\(safeKey).value') \(dir)"

            case .limit(let count, let offset):
                limitClause = "LIMIT \(count) OFFSET \(offset)"

            default:
                break
            }
        }

        if let externalLimit, limitClause == nil {
            limitClause = "LIMIT \(externalLimit)"
        }

        var sql = """
            SELECT id, label, properties, created_at, modified_at, revision, is_deleted
            FROM nodes WHERE \(clauses.joined(separator: " AND "))
            """
        if let orderBy { sql += " \(orderBy)" }
        if let limitClause { sql += " \(limitClause)" }
        return (sql, bindings)
    }

    private func sqlOpString(_ op: SQLFilterOp) -> String {
        switch op {
        case .equals:              return "="
        case .notEquals:           return "!="
        case .greaterThan:         return ">"
        case .greaterThanOrEqual:  return ">="
        case .lessThan:            return "<"
        case .lessThanOrEqual:     return "<="
        }
    }

    private func sqlValueComponents(for value: PropertyValue) -> (typeTag: String, sqlValue: SQLValue) {
        switch value {
        case .string(let s):  return ("string", .text(s))
        case .int(let i):     return ("int", .integer(i))
        case .double(let d):  return ("double", .real(d))
        case .bool(let b):    return ("bool", .integer(b ? 1 : 0))
        case .date(let d):    return ("date", .real(d.timeIntervalSince1970))
        case .null:           return ("null", .text("null"))
        case .data:           return ("data", .text(""))
        case .array:          return ("array", .text(""))
        }
    }

    /// Reject property keys that could break the json_extract path.
    private func sanitizeJSONKey(_ key: String) -> String {
        key.filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: Legacy per-stage path

    private func legacyPath(externalLimit: Int?) throws -> ExecutionResult {
        var orderedIDs: [NodeID] = []
        var edges: [Edge] = []

        for (i, stage) in stages.enumerated() {
            switch stage {
            case .label(let label):
                let matches = snapshot.labelIndex.nodes(labeled: label)
                orderedIDs = Array(matches)

            case .singleID(let id):
                if let _ = snapshot.indexMap.internalIndex(for: id) {
                    orderedIDs = [id]
                }

            case .scan:
                let allLabeled = snapshot.labelIndex.allLiveNodeIDs()
                orderedIDs = Array(allLabeled)

            case .traverse(let direction, let edgeType, let depth):
                let result = try traverse(
                    fromIDs: orderedIDs,
                    direction: direction,
                    edge: edgeType,
                    depth: depth
                )
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

            case .sqlWhere, .sqlContains, .sorted, .limit:
                // These should have been handled by sqlPushdownPath, but if mixed with
                // non-pushable stages, apply them in-memory as a best-effort fallback.
                let nodeRepo = NodeRepository(store: store)
                switch stage {
                case .sqlWhere(let key, let op, let value):
                    var kept: [NodeID] = []
                    for id in orderedIDs {
                        if let node = try nodeRepo.fetch(id: id) {
                            if evaluateInMemory(node: node, key: key, op: op, value: value) {
                                kept.append(id)
                            }
                        }
                    }
                    orderedIDs = kept
                case .sqlContains(let key, let substring):
                    var kept: [NodeID] = []
                    for id in orderedIDs {
                        if let node = try nodeRepo.fetch(id: id),
                           case .string(let s) = node.properties[key],
                           s.localizedCaseInsensitiveContains(substring) {
                            kept.append(id)
                        }
                    }
                    orderedIDs = kept
                case .sorted(let key, let order):
                    let materialised: [(NodeID, PropertyValue?)] = try orderedIDs.map { id in
                        let node = try nodeRepo.fetch(id: id)
                        return (id, node?.properties[key])
                    }
                    orderedIDs = materialised.sorted { a, b in
                        guard let va = a.1, let vb = b.1 else { return a.1 != nil }
                        let cmp = GraphStore.compare(va, vb)
                        return order == .ascending ? cmp == .less : cmp == .greater
                    }.map(\.0)
                case .limit(let count, let offset):
                    orderedIDs = Array(orderedIDs.dropFirst(offset).prefix(count))
                default: break
                }
            }

            if i == stages.count - 1, let externalLimit, orderedIDs.count > externalLimit {
                orderedIDs = Array(orderedIDs.prefix(externalLimit))
            }
        }

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

    private func evaluateInMemory(node: Node, key: String, op: SQLFilterOp, value: PropertyValue) -> Bool {
        guard let prop = node.properties[key] else { return false }
        let cmp = GraphStore.compare(prop, value)
        switch op {
        case .equals:              return cmp == .equal
        case .notEquals:           return cmp != .equal
        case .greaterThan:         return cmp == .greater
        case .greaterThanOrEqual:  return cmp == .greater || cmp == .equal
        case .lessThan:            return cmp == .less
        case .lessThanOrEqual:     return cmp == .less || cmp == .equal
        }
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
