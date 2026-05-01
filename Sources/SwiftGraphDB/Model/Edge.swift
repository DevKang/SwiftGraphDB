import Foundation

/// A directed edge between two nodes.
///
/// Like `Node`, edges carry identity equality: two `Edge` values are `==` iff they share the same
/// `id`, regardless of any divergence in their `type`, endpoints, or `properties`.
public struct Edge: Sendable, Codable {
    public let id: EdgeID
    public var type: String
    public let fromID: NodeID
    public let toID: NodeID
    public var properties: [String: PropertyValue]
    public let createdAt: Date
    public var modifiedAt: Date

    public init(
        id: EdgeID = IDFactory.live.edgeID(),
        type: String,
        fromID: NodeID,
        toID: NodeID,
        properties: [String: PropertyValue] = [:],
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.fromID = fromID
        self.toID = toID
        self.properties = properties
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Returns a copy with the given properties merged in. Existing keys are overwritten;
    /// other keys are preserved. `modifiedAt` is bumped to `Date()`.
    public func with(properties patch: [String: PropertyValue]) -> Edge {
        var merged = self.properties
        for (k, v) in patch { merged[k] = v }
        return Edge(
            id: id,
            type: type,
            fromID: fromID,
            toID: toID,
            properties: merged,
            createdAt: createdAt,
            modifiedAt: Date()
        )
    }
}

extension Edge: Hashable {
    public static func == (lhs: Edge, rhs: Edge) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
