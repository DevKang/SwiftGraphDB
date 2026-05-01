import Foundation

/// Declarative spec for a property equality index. Indexes are declared once at store-open time
/// (SPEC §15.3 closes this question). Runtime declare/drop is deferred — runtime changes would
/// require a streaming rebuild from SQLite.
public struct PropertyIndexSpec: Sendable, Hashable {
    public let label: String
    public let property: String
    public init(label: String, property: String) {
        self.label = label
        self.property = property
    }
}

/// Optional in-memory equality indexes for `(label, property)` pairs.
///
/// Updated synchronously by the M4 graph actor on node create / update / delete and rebuilt from
/// SQLite on open. Queries against an undeclared `(label, property)` return `nil` — the query
/// engine falls back to a SQL scan.
///
/// Only equality predicates are supported; range queries are deferred.
public struct PropertyIndex: Sendable {

    private let specs: Set<PropertyIndexSpec>
    private var buckets: [PropertyIndexSpec: [PropertyValue: Set<NodeID>]]

    public init(specs: some Sequence<PropertyIndexSpec>) {
        let set = Set(specs)
        self.specs = set
        self.buckets = Dictionary(uniqueKeysWithValues: set.map { ($0, [:]) })
    }

    public init(specs: some Sequence<PropertyIndexSpec>, from nodes: some Sequence<Node>) {
        self.init(specs: specs)
        for node in nodes { self.insert(node) }
    }

    /// Returns the set of node ids whose `(label, property)` matches `value`. Returns `nil` if no
    /// such index is declared.
    public func nodes(
        label: String,
        property: String,
        equals value: PropertyValue
    ) -> Set<NodeID>? {
        let spec = PropertyIndexSpec(label: label, property: property)
        guard let bucket = buckets[spec] else { return nil }
        return bucket[value] ?? []
    }

    public mutating func insert(_ node: Node) {
        for spec in specs where spec.label == node.label {
            guard let value = node.properties[spec.property] else { continue }
            buckets[spec, default: [:]][value, default: []].insert(node.id)
        }
    }

    public mutating func delete(_ node: Node) {
        for spec in specs where spec.label == node.label {
            guard let value = node.properties[spec.property] else { continue }
            removeFromBucket(spec: spec, value: value, id: node.id)
        }
    }

    /// Move a node between value buckets when its indexed properties change. Either `from` or
    /// `to` may have absent / different values for the indexed properties; we patch each spec
    /// independently.
    public mutating func update(from old: Node, to new: Node) {
        // Label may have changed too; remove for old.label, add for new.label.
        for spec in specs {
            let oldValue = (spec.label == old.label) ? old.properties[spec.property] : nil
            let newValue = (spec.label == new.label) ? new.properties[spec.property] : nil

            if oldValue == newValue, old.label == new.label { continue }

            if let oldValue {
                removeFromBucket(spec: spec, value: oldValue, id: old.id)
            }
            if let newValue {
                buckets[spec, default: [:]][newValue, default: []].insert(new.id)
            }
        }
    }

    private mutating func removeFromBucket(
        spec: PropertyIndexSpec,
        value: PropertyValue,
        id: NodeID
    ) {
        guard var byValue = buckets[spec], var ids = byValue[value] else { return }
        ids.remove(id)
        if ids.isEmpty {
            byValue.removeValue(forKey: value)
        } else {
            byValue[value] = ids
        }
        buckets[spec] = byValue
    }
}
