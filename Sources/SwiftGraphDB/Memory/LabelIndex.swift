import Foundation

/// In-memory `[String: Set<NodeID>]` keyed by label.
///
/// SPEC §5.5. Updated synchronously on every node create / update / delete and rebuilt from
/// SQLite on open. The index trades memory for O(1) `nodes(labeled:)` lookups; for graphs in
/// SPEC §10's target range (10K – 500K nodes) the `Set<NodeID>` overhead is well under the
/// in-memory budget.
public struct LabelIndex: Sendable {

    private var byLabel: [String: Set<NodeID>] = [:]

    public init() {}

    /// Build from a sequence of `(id, label)` rows. Used by the M4 rebuild path.
    public init(rows: some Sequence<(NodeID, String)>) {
        for (id, label) in rows { add(id, label: label) }
    }

    /// Returns the set of live node ids carrying `label`. Empty set (not nil) for unknown
    /// labels so callers don't need an extra branch.
    public func nodes(labeled label: String) -> Set<NodeID> {
        byLabel[label] ?? []
    }

    public mutating func add(_ id: NodeID, label: String) {
        byLabel[label, default: []].insert(id)
    }

    public mutating func remove(_ id: NodeID, label: String) {
        guard var bucket = byLabel[label] else { return }
        bucket.remove(id)
        if bucket.isEmpty {
            byLabel.removeValue(forKey: label)
        } else {
            byLabel[label] = bucket
        }
    }

    /// Move a node from one label to another atomically — at no point does it appear in both
    /// label buckets.
    public mutating func update(_ id: NodeID, from oldLabel: String, to newLabel: String) {
        guard oldLabel != newLabel else { return }
        remove(id, label: oldLabel)
        add(id, label: newLabel)
    }
}
