import Foundation

/// Bidirectional mapping between public `NodeID` (UUID) and a compact internal `Int` index.
///
/// Hot traversal paths chase contiguous `Int` offsets into CSR arrays, so we cannot afford to
/// hash 16-byte UUIDs at every step. `IndexMap` interns each UUID to a dense integer assigned in
/// interning order. Released slots are reused by subsequent `intern` calls so the dense range
/// stays compact through node deletion and compaction.
///
/// The mapping is intentionally **not** persisted on disk — it is rebuilt from SQLite on every
/// open. Persisting the mapping would couple the snapshot format to an in-memory invariant, and
/// the cost of rebuilding a 100K-node mapping is well under one second on a modern device.
///
/// Concurrency: `IndexMap` is a value type but is not safe for concurrent mutation. The graph
/// actor (M4) owns the live instance; tests use it from a single task.
public struct IndexMap: Sendable {

    private var forward: [NodeID: Int] = [:]
    private var reverse: [NodeID?] = [] // nil entries are free slots
    private var freeList: [Int] = []

    public init() {}

    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        forward.reserveCapacity(minimumCapacity)
        reverse.reserveCapacity(minimumCapacity)
    }

    /// Look up the internal index for `id`. Returns `nil` if the id has never been interned or
    /// has been released.
    public func internalIndex(for id: NodeID) -> Int? {
        forward[id]
    }

    /// Look up the `NodeID` at a given internal index. Returns `nil` if the index is out of
    /// range or has been released.
    public func nodeID(at index: Int) -> NodeID? {
        guard index >= 0, index < reverse.count else { return nil }
        return reverse[index]
    }

    /// Assign `id` an internal index, or return its existing index if already interned. Reuses
    /// a released slot if one is available so the dense range stays compact.
    @discardableResult
    public mutating func intern(_ id: NodeID) -> Int {
        if let existing = forward[id] { return existing }
        let index: Int
        if let recycled = freeList.popLast() {
            index = recycled
            reverse[recycled] = id
        } else {
            index = reverse.count
            reverse.append(id)
        }
        forward[id] = index
        return index
    }

    /// Mark a slot as free. Subsequent `intern` calls may reuse this index. Looking up the old
    /// id returns `nil` immediately.
    public mutating func release(_ index: Int) {
        guard index >= 0, index < reverse.count, let id = reverse[index] else { return }
        forward.removeValue(forKey: id)
        reverse[index] = nil
        freeList.append(index)
    }

    /// Number of currently interned ids (excludes released slots). Mostly useful in tests.
    public var count: Int { forward.count }
}
