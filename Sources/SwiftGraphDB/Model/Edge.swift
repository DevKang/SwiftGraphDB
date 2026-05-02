import Foundation

/// A directed edge between two nodes.
///
/// Like `Node`, edges carry identity equality: two `Edge` values are `==` iff they share the same
/// `id`, regardless of divergence in `type`, endpoints, `properties`, `revision`, or `isDeleted`.
public struct Edge: Sendable {
    public let id: EdgeID
    public var type: String
    public let fromID: NodeID
    public let toID: NodeID
    public var properties: [String: PropertyValue]
    public let createdAt: Date
    public var modifiedAt: Date
    public var revision: GraphRevision
    public var isDeleted: Bool

    public init(
        id: EdgeID = IDFactory.live.edgeID(),
        type: String,
        fromID: NodeID,
        toID: NodeID,
        properties: [String: PropertyValue] = [:],
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        revision: GraphRevision? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.type = type
        self.fromID = fromID
        self.toID = toID
        self.properties = properties
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.revision = revision ?? GraphRevision.placeholder(wallClock: createdAt)
        self.isDeleted = isDeleted
    }

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
            modifiedAt: Date(),
            revision: revision,
            isDeleted: isDeleted
        )
    }
}

extension Edge: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, type, fromID, toID, properties, createdAt, modifiedAt, revision, isDeleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(EdgeID.self, forKey: .id)
        let type = try c.decode(String.self, forKey: .type)
        let fromID = try c.decode(NodeID.self, forKey: .fromID)
        let toID = try c.decode(NodeID.self, forKey: .toID)
        let properties = try c.decode([String: PropertyValue].self, forKey: .properties)
        let createdAt = try c.decode(Date.self, forKey: .createdAt)
        let modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        let revision = try c.decodeIfPresent(GraphRevision.self, forKey: .revision)
            ?? GraphRevision.placeholder(wallClock: createdAt)
        let isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        self.init(id: id, type: type, fromID: fromID, toID: toID, properties: properties,
                  createdAt: createdAt, modifiedAt: modifiedAt,
                  revision: revision, isDeleted: isDeleted)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(fromID, forKey: .fromID)
        try c.encode(toID, forKey: .toID)
        try c.encode(properties, forKey: .properties)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(modifiedAt, forKey: .modifiedAt)
        try c.encode(revision, forKey: .revision)
        try c.encode(isDeleted, forKey: .isDeleted)
    }
}

extension Edge: Hashable {
    public static func == (lhs: Edge, rhs: Edge) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
