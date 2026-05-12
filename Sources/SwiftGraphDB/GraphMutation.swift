import Foundation

/// Describes a single mutation event on the graph. Emitted by `GraphStore.changes`.
public enum GraphMutation: Sendable {
    case nodeAdded(NodeID, label: String)
    case nodeUpdated(NodeID)
    case nodeDeleted(NodeID)
    case edgeAdded(EdgeID, type: String, from: NodeID, to: NodeID)
    case edgeUpdated(EdgeID)
    case edgeDeleted(EdgeID)
}
