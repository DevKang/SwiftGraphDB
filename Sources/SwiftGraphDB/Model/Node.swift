import Foundation

/// A node in the property graph.
///
/// Nodes are durable identities. Two `Node` values are `==` iff they share the same `id`, even if
/// their `label`, `properties`, or `revision` differ — this matches the durable-entity model
/// where a `Node` returned from a query is a snapshot of state rather than the canonical record.
///
/// `revision` and `isDeleted` are part of SPEC §3.1 (v0.2). The `GraphActor` stamps `revision`
/// on commit; before that point newly-constructed nodes carry `GraphRevision.placeholder()`.
public struct Node: Sendable {
    public let id: NodeID
    /// The primary label (first element of `labels`). Backward-compatible accessor.
    public var label: String { labels.sorted().first ?? "" }
    /// All labels assigned to this node.
    public var labels: Set<String>
    public var properties: [String: PropertyValue]
    public let createdAt: Date
    public var modifiedAt: Date
    public var revision: GraphRevision
    public var isDeleted: Bool

    public init(
        id: NodeID = IDFactory.live.nodeID(),
        label: String,
        properties: [String: PropertyValue] = [:],
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        revision: GraphRevision? = nil,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.labels = [label]
        self.properties = properties
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.revision = revision ?? GraphRevision.placeholder(wallClock: createdAt)
        self.isDeleted = isDeleted
    }

    /// Multi-label initializer.
    public init(
        id: NodeID = IDFactory.live.nodeID(),
        labels: Set<String>,
        properties: [String: PropertyValue] = [:],
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        revision: GraphRevision? = nil,
        isDeleted: Bool = false
    ) {
        precondition(!labels.isEmpty, "Node must have at least one label")
        self.id = id
        self.labels = labels
        self.properties = properties
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.revision = revision ?? GraphRevision.placeholder(wallClock: createdAt)
        self.isDeleted = isDeleted
    }

    /// Returns a copy with the given properties merged in. Existing keys are overwritten;
    /// other keys are preserved. Setting a value to `.null` removes the key.
    /// `modifiedAt` is bumped; `revision` is intentionally preserved — the commit path
    /// is responsible for stamping a fresh revision.
    public func with(properties patch: [String: PropertyValue]) -> Node {
        var merged = self.properties
        for (k, v) in patch {
            if case .null = v { merged.removeValue(forKey: k) }
            else { merged[k] = v }
        }
        return Node(
            id: id,
            labels: labels,
            properties: merged,
            createdAt: createdAt,
            modifiedAt: Date(),
            revision: revision,
            isDeleted: isDeleted
        )
    }
}

extension Node: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, label, labels, properties, createdAt, modifiedAt, revision, isDeleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(NodeID.self, forKey: .id)
        // Decode labels: prefer `labels` array, fall back to single `label` for backward compat.
        let labels: Set<String>
        if let labelsArray = try c.decodeIfPresent(Set<String>.self, forKey: .labels), !labelsArray.isEmpty {
            labels = labelsArray
        } else {
            let singleLabel = try c.decode(String.self, forKey: .label)
            labels = [singleLabel]
        }
        let properties = try c.decode([String: PropertyValue].self, forKey: .properties)
        let createdAt = try c.decode(Date.self, forKey: .createdAt)
        let modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        let revision = try c.decodeIfPresent(GraphRevision.self, forKey: .revision)
            ?? GraphRevision.placeholder(wallClock: createdAt)
        let isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        self.init(id: id, labels: labels, properties: properties,
                  createdAt: createdAt, modifiedAt: modifiedAt,
                  revision: revision, isDeleted: isDeleted)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(labels, forKey: .labels)
        try c.encode(properties, forKey: .properties)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(modifiedAt, forKey: .modifiedAt)
        try c.encode(revision, forKey: .revision)
        try c.encode(isDeleted, forKey: .isDeleted)
    }
}

extension Node: Hashable {
    public static func == (lhs: Node, rhs: Node) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
