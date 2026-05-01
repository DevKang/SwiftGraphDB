import Foundation

/// Folds the `EdgeLog` into the CSR structures, returning fresh forward / reverse adjacencies
/// and an empty log. SPEC §5.4.
///
/// `Compactor` is stateless. The graph actor (M4) calls `compact` when the policy reports
/// `shouldCompact(...)` is true, on app backgrounding, or on an explicit `graph.compact()`
/// request. Queries never observe a half-compacted state because compaction returns a brand-new
/// state value — the actor swaps it in atomically.
public enum Compactor {

    public struct State: Sendable {
        public var indexMap: IndexMap
        public var forward: CSRAdjacency
        public var reverse: CSRAdjacency
        public var log: EdgeLog

        public init(indexMap: IndexMap, forward: CSRAdjacency, reverse: CSRAdjacency, log: EdgeLog) {
            self.indexMap = indexMap
            self.forward = forward
            self.reverse = reverse
            self.log = log
        }
    }

    /// Decides when compaction should run.
    public struct Policy: Sendable {
        /// Compaction triggers when `log.size > nodeCount * thresholdMultiplier`.
        public var thresholdMultiplier: Int

        public init(thresholdMultiplier: Int = 4) {
            self.thresholdMultiplier = thresholdMultiplier
        }

        public func shouldCompact(nodeCount: Int, logSize: Int) -> Bool {
            logSize > max(1, nodeCount) * thresholdMultiplier
        }
    }

    /// Pure: returns a new state with the log folded in. The input is left untouched.
    public static func compact(_ state: State) -> State {
        if state.log.isEmpty { return state }

        let nodeCount = state.indexMap.countIncludingFreed

        // Reuse the existing EdgeLog merge to compute the live edge set per source. The result
        // is the canonical edge list — we then re-bucket it for CSR forward + reverse.
        var liveEdges: [(from: Int, EdgeRecord)] = []
        var liveReverseEdges: [(from: Int, EdgeRecord)] = []
        liveEdges.reserveCapacity(state.forward.edges.count + state.log.size)
        liveReverseEdges.reserveCapacity(state.reverse.edges.count + state.log.size)

        // Walk every internal index that may have outgoing edges in either CSR or log.
        var sourceIndices = Set<Int>()
        for i in 0..<nodeCount where state.forward.degree(of: i) > 0 {
            sourceIndices.insert(i)
        }
        for entry in state.log.entries {
            if let i = state.indexMap.internalIndex(for: entry.fromID) {
                sourceIndices.insert(i)
            }
        }

        for sourceIndex in sourceIndices.sorted() {
            guard let sourceID = state.indexMap.nodeID(at: sourceIndex) else { continue }
            let csrSlice = state.forward.neighbours(of: sourceIndex)
            let logSlice = state.log.outgoingEntries(from: sourceID)
            let merged = EdgeLog.merge(csrEdges: csrSlice, logEntries: logSlice)
            for record in merged {
                liveEdges.append((sourceIndex, record))
                if let reverseIndex = state.indexMap.internalIndex(for: record.toID) {
                    liveReverseEdges.append((
                        reverseIndex,
                        EdgeRecord(toID: sourceID, edgeID: record.edgeID, type: record.type)
                    ))
                }
            }
        }

        return State(
            indexMap: state.indexMap,
            forward: CSRAdjacency(nodeCount: nodeCount, edges: liveEdges),
            reverse: CSRAdjacency(nodeCount: nodeCount, edges: liveReverseEdges),
            log: EdgeLog()
        )
    }
}
