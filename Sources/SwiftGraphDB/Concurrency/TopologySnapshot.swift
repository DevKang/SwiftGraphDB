import Foundation

/// An immutable, off-actor view of the graph's in-memory topology at a single instant.
///
/// SPEC §8.3. Hot traversal cannot afford an actor hop per visited node. The pattern: take a
/// snapshot once (one hop), then walk it off-actor. Because every component is a `Sendable`
/// value type and Swift's COW gives O(1) capture, this is cheap.
///
/// Snapshot semantics:
/// - **Frozen at capture.** Writes that land on the actor after the snapshot is taken are
///   invisible to it. Read-your-own-writes does *not* hold across snapshots — a caller that
///   needs the latest view must take a new snapshot.
/// - **Consistent.** Every component reflects the same logical instant. The actor returns the
///   snapshot synchronously; intermediate writes wait their turn.
public struct TopologySnapshot: Sendable {
    public let indexMap: IndexMap
    public let forward: CSRAdjacency
    public let reverse: CSRAdjacency
    public let edgeLog: EdgeLog
    public let labelIndex: LabelIndex
    public let createdAt: Date

    public init(
        indexMap: IndexMap,
        forward: CSRAdjacency,
        reverse: CSRAdjacency,
        edgeLog: EdgeLog,
        labelIndex: LabelIndex,
        createdAt: Date = Date()
    ) {
        self.indexMap = indexMap
        self.forward = forward
        self.reverse = reverse
        self.edgeLog = edgeLog
        self.labelIndex = labelIndex
        self.createdAt = createdAt
    }
}

extension GraphActor {
    /// Capture the current in-memory topology. The returned value is fully `Sendable`; further
    /// writes to the actor do not mutate it.
    public func snapshotTopology() -> TopologySnapshot {
        let s = snapshotForTests()
        return TopologySnapshot(
            indexMap: s.indexMap,
            forward: s.forward,
            reverse: s.reverse,
            edgeLog: s.edgeLog,
            labelIndex: s.labelIndex
        )
    }
}
