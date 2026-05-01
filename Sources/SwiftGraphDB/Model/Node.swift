import Foundation

public struct Node: Sendable, Hashable {
    public let id: NodeID
    public var label: String
    public var properties: [String: PropertyValue]
    public let createdAt: Date
    public var modifiedAt: Date

    public init(
        id: NodeID = UUID(),
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
}
