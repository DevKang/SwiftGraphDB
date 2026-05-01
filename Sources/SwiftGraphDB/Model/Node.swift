import Foundation

/// A node in the property graph.
///
/// Nodes are durable identities. Two `Node` values are `==` iff they share the same `id`, even if
/// their `label` or `properties` differ — this matches the durable-entity model where a `Node`
/// returned from a query is a snapshot of state rather than the canonical record.
public struct Node: Sendable, Codable {
    public let id: NodeID
    public var label: String
    public var properties: [String: PropertyValue]
    public let createdAt: Date
    public var modifiedAt: Date

    public init(
        id: NodeID = IDFactory.live.nodeID(),
        label: String,
        properties: [String: PropertyValue] = [:],
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.properties = properties
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Returns a copy with the given properties merged in. Existing keys are overwritten;
    /// other keys are preserved. `modifiedAt` is bumped to `Date()`.
    public func with(properties patch: [String: PropertyValue]) -> Node {
        var merged = self.properties
        for (k, v) in patch { merged[k] = v }
        return Node(
            id: id,
            label: label,
            properties: merged,
            createdAt: createdAt,
            modifiedAt: Date()
        )
    }
}

extension Node: Hashable {
    public static func == (lhs: Node, rhs: Node) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
