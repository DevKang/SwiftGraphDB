import Foundation

/// Lazy edge-query pipeline, mirroring `NodeQuery` for edges.
/// Supports SQL-pushdown filtering, sorting, and pagination via `json_extract()`.
public struct EdgeQuery: Sendable {

    let store: SQLiteStore
    let stages: [Stage]

    enum Stage: Sendable {
        case ofType(String)
        case fromNode(NodeID)
        case toNode(NodeID)
        case scan
        case filterPredicate(@Sendable (Edge) -> Bool)
        // SQL-pushdown stages
        case sqlWhere(key: String, op: SQLFilterOp, value: PropertyValue)
        case sqlContains(key: String, substring: String)
        case sorted(key: String, order: SortOrder)
        case limit(count: Int, offset: Int)
    }

    func appending(_ stage: Stage) -> EdgeQuery {
        EdgeQuery(store: store, stages: stages + [stage])
    }

    // MARK: - Filter operations

    /// Property filter pushed down to SQLite `json_extract()`.
    public func `where`(_ key: String, _ op: SQLFilterOp, _ value: PropertyValue) -> EdgeQuery {
        appending(.sqlWhere(key: key, op: op, value: value))
    }

    /// String-contains filter pushed down to SQLite `LIKE`.
    public func `where`(_ key: String, contains substring: String) -> EdgeQuery {
        appending(.sqlContains(key: key, substring: substring))
    }

    /// Escape-hatch closure filter.
    public func `where`(_ predicate: @escaping @Sendable (Edge) -> Bool) -> EdgeQuery {
        appending(.filterPredicate(predicate))
    }

    /// Sort results by a property key.
    public func sorted(by key: String, _ order: SortOrder = .ascending) -> EdgeQuery {
        appending(.sorted(key: key, order: order))
    }

    /// Limit the number of returned edges, with optional offset.
    public func limit(_ count: Int, offset: Int = 0) -> EdgeQuery {
        appending(.limit(count: count, offset: offset))
    }

    // MARK: - Terminal operations

    /// Materialise the query into an array of `Edge` values.
    public func collect() throws -> [Edge] {
        if let result = try sqlPushdownPath() {
            return result
        }
        return try legacyPath()
    }

    /// Count of matching edges.
    public func count() throws -> Int {
        try collect().count
    }

    /// First matching edge, or nil.
    public func first() throws -> Edge? {
        try collect().first
    }

    /// `true` iff at least one edge matches.
    public func exists() throws -> Bool {
        try first() != nil
    }

    // MARK: - SQL pushdown

    private func sqlPushdownPath() throws -> [Edge]? {
        guard !stages.isEmpty else { return nil }
        let first = stages[0]

        var baseClauses: [String] = ["is_deleted = 0"]
        var baseBindings: [SQLValue] = []

        switch first {
        case .ofType(let t):
            baseClauses.append("type = ?")
            baseBindings.append(.text(t))
        case .fromNode(let id):
            baseClauses.append("from_id = ?")
            baseBindings.append(.text(id.uuidString))
        case .toNode(let id):
            baseClauses.append("to_id = ?")
            baseBindings.append(.text(id.uuidString))
        case .scan:
            break
        default:
            return nil
        }

        let rest = Array(stages.dropFirst())
        for stage in rest {
            switch stage {
            case .sqlWhere, .sqlContains, .sorted, .limit: continue
            case .filterPredicate: return nil // can't pushdown closures
            default: return nil
            }
        }

        let (sql, bindings) = buildSQLQuery(baseClauses: baseClauses, baseBindings: baseBindings, sqlStages: rest)
        return try store.query(sql, bindings) { try EdgeRepository.decodeRow($0) }
    }

    private func buildSQLQuery(
        baseClauses: [String],
        baseBindings: [SQLValue],
        sqlStages: [Stage]
    ) -> (String, [SQLValue]) {
        var clauses = baseClauses
        var bindings = baseBindings
        var orderBy: String?
        var limitClause: String?

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
                limitClause = offset > 0 ? "LIMIT \(count) OFFSET \(offset)" : "LIMIT \(count)"

            default: break
            }
        }

        var sql = "SELECT * FROM edges WHERE " + clauses.joined(separator: " AND ")
        if let orderBy { sql += " \(orderBy)" }
        if let limitClause { sql += " \(limitClause)" }
        return (sql, bindings)
    }

    // MARK: - Legacy (in-memory) path

    private func legacyPath() throws -> [Edge] {
        guard !stages.isEmpty else { return [] }

        // Start from the source
        var edges: [Edge]
        switch stages[0] {
        case .ofType(let t):
            edges = try EdgeRepository(store: store).fetchAll(type: t)
        case .fromNode(let id):
            edges = try EdgeRepository(store: store).fetchOutgoing(from: id, type: nil)
        case .toNode(let id):
            edges = try EdgeRepository(store: store).fetchIncoming(to: id, type: nil)
        case .scan:
            edges = try store.query(
                "SELECT * FROM edges WHERE is_deleted = 0"
            ) { try EdgeRepository.decodeRow($0) }
        default:
            edges = []
        }

        for stage in stages.dropFirst() {
            switch stage {
            case .filterPredicate(let pred):
                edges = edges.filter(pred)
            case .sqlWhere(let key, let op, let value):
                edges = edges.filter { evaluateInMemory($0, key: key, op: op, value: value) }
            case .sqlContains(let key, let substring):
                edges = edges.filter {
                    guard case .string(let s) = $0.properties[key] else { return false }
                    return s.localizedCaseInsensitiveContains(substring)
                }
            case .sorted(let key, let order):
                edges.sort { a, b in
                    let va = a.properties[key]
                    let vb = b.properties[key]
                    guard let va, let vb else { return va != nil }
                    let cmp = GraphStore.compare(va, vb)
                    return order == .ascending ? cmp == .less : cmp == .greater
                }
            case .limit(let count, let offset):
                let start = min(offset, edges.count)
                let end = min(start + count, edges.count)
                edges = Array(edges[start..<end])
            default: break
            }
        }
        return edges
    }

    // MARK: - Shared helpers (same as NodeQuery's QueryExecutor)

    private func sanitizeJSONKey(_ key: String) -> String {
        key.replacingOccurrences(of: "'", with: "")
           .replacingOccurrences(of: "\\", with: "")
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

    private func sqlValueComponents(for value: PropertyValue) -> (String, SQLValue) {
        switch value {
        case .string(let s): return ("string", .text(s))
        case .int(let i):    return ("int",    .integer(i))
        case .double(let d): return ("double", .real(d))
        case .bool(let b):   return ("bool",   .integer(b ? 1 : 0))
        default:             return ("string", .text("\(value)"))
        }
    }

    private func evaluateInMemory(_ edge: Edge, key: String, op: SQLFilterOp, value: PropertyValue) -> Bool {
        guard let prop = edge.properties[key] else { return false }
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
