import Foundation

/// Bounded LRU cache. O(1) `get` / `put` / `remove`. Used by the `GraphActor` to cache decoded
/// `Node.properties` so the SPEC §13 sub-millisecond fetch target is reachable without keeping
/// every property dictionary resident.
///
/// Concurrency: not safe for concurrent mutation; the actor owns the live instance.
public struct LRUCache<Key: Hashable, Value>: @unchecked Sendable where Key: Sendable, Value: Sendable {

    public let capacity: Int

    private final class Node {
        var key: Key
        var value: Value
        var prev: Node?
        var next: Node?
        init(_ key: Key, _ value: Value) { self.key = key; self.value = value }
    }

    private var lookup: [Key: Node] = [:]
    private var head: Node?
    private var tail: Node?

    public init(capacity: Int) {
        precondition(capacity > 0, "LRUCache capacity must be positive")
        self.capacity = capacity
    }

    public var count: Int { lookup.count }
    public var isEmpty: Bool { lookup.isEmpty }

    public mutating func get(_ key: Key) -> Value? {
        guard let node = lookup[key] else { return nil }
        moveToHead(node)
        return node.value
    }

    public mutating func put(_ key: Key, _ value: Value) {
        if let node = lookup[key] {
            node.value = value
            moveToHead(node)
            return
        }
        let node = Node(key, value)
        lookup[key] = node
        attachAtHead(node)
        if lookup.count > capacity {
            evictTail()
        }
    }

    public mutating func remove(_ key: Key) {
        guard let node = lookup.removeValue(forKey: key) else { return }
        detach(node)
    }

    public mutating func removeAll() {
        lookup.removeAll()
        head = nil
        tail = nil
    }

    // MARK: - Internals

    private mutating func attachAtHead(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private mutating func moveToHead(_ node: Node) {
        guard head !== node else { return }
        detach(node)
        attachAtHead(node)
    }

    private mutating func detach(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private mutating func evictTail() {
        guard let tail else { return }
        lookup.removeValue(forKey: tail.key)
        detach(tail)
    }
}
