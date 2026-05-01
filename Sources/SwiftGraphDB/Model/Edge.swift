import Foundation

public struct Edge: Sendable, Hashable {
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
}
