import Foundation

/// One adjacency record in the CSR `edges` array.
public struct EdgeRecord: Sendable, Equatable {
    public let toID: NodeID
    public let edgeID: EdgeID
    public let type: String

    public init(toID: NodeID, edgeID: EdgeID, type: String) {
        self.toID = toID
        self.edgeID = edgeID
        self.type = type
    }
}

/// Compressed Sparse Row adjacency. Two contiguous arrays:
/// - `offsets[i] ..< offsets[i+1]` is the slice of `edges` belonging to internal index `i`.
/// - `edges` is a flat list of `EdgeRecord` ordered by source index, then by insertion.
///
/// SPEC §5.1. CSR is a **read-optimised** structure. Mutation is not supported on the value
/// directly — writes go through `EdgeLog` and are merged into a fresh CSR by compaction
/// (OML-1933). Constructing a new CSR from an updated edge set is also acceptable.
public struct CSRAdjacency: Sendable, Equatable {

    public let offsets: [Int]
    public let edges: [EdgeRecord]

    /// Manual / test builder. `edges` is a flat list of `(fromInternalIndex, EdgeRecord)`.
    public init(nodeCount: Int, edges flatEdges: [(from: Int, EdgeRecord)]) {
        // Bucket per source index, preserving insertion order within a bucket.
        var buckets: [[EdgeRecord]] = Array(repeating: [], count: nodeCount)
        for (from, record) in flatEdges {
            precondition(from >= 0 && from < nodeCount, "from index out of range")
            buckets[from].append(record)
        }
        var offsets: [Int] = []
        offsets.reserveCapacity(nodeCount + 1)
        var packed: [EdgeRecord] = []
        packed.reserveCapacity(flatEdges.count)
        offsets.append(0)
        for bucket in buckets {
            packed.append(contentsOf: bucket)
            offsets.append(packed.count)
        }
        self.offsets = offsets
        self.edges = packed
    }

    /// Forward adjacency: edges keyed by `fromID`. Edges whose endpoints are not in `indexMap`
    /// are skipped (the caller is responsible for interning before building).
    public init(forwardFrom edges: some Sequence<Edge>, indexMap: IndexMap) {
        let nodeCount = max(0, indexMap.maxIndexExclusive)
        var flat: [(from: Int, EdgeRecord)] = []
        for edge in edges {
            guard let fromIndex = indexMap.internalIndex(for: edge.fromID) else { continue }
            flat.append((fromIndex, EdgeRecord(toID: edge.toID, edgeID: edge.id, type: edge.type)))
        }
        self.init(nodeCount: nodeCount, edges: flat)
    }

    /// Reverse adjacency: edges keyed by `toID`. The `toID` field of each `EdgeRecord` then
    /// holds the *source* node — symmetry by mirroring rather than introducing a separate type.
    public init(reverseFrom edges: some Sequence<Edge>, indexMap: IndexMap) {
        let nodeCount = max(0, indexMap.maxIndexExclusive)
        var flat: [(from: Int, EdgeRecord)] = []
        for edge in edges {
            guard let toIndex = indexMap.internalIndex(for: edge.toID) else { continue }
            // For the reverse map, the "neighbour" we expose is the original fromID.
            flat.append((toIndex, EdgeRecord(toID: edge.fromID, edgeID: edge.id, type: edge.type)))
        }
        self.init(nodeCount: nodeCount, edges: flat)
    }

    public var nodeCount: Int { max(0, offsets.count - 1) }

    /// Slice of neighbours for `internalIndex`. Out-of-range indexes return an empty slice
    /// rather than crashing — keeps traversal callers simple.
    public func neighbours(of internalIndex: Int) -> ArraySlice<EdgeRecord> {
        guard internalIndex >= 0, internalIndex < nodeCount else { return [] }
        let start = offsets[internalIndex]
        let end = offsets[internalIndex + 1]
        return edges[start..<end]
    }

    public func degree(of internalIndex: Int) -> Int {
        guard internalIndex >= 0, internalIndex < nodeCount else { return 0 }
        return offsets[internalIndex + 1] - offsets[internalIndex]
    }
}

extension IndexMap {
    /// Highest valid internal index + 1. Used by CSR builders to size their offsets array.
    /// Stays correct in the presence of released slots (we still reserve capacity for the
    /// largest allocated index).
    var maxIndexExclusive: Int {
        // The reverse buffer is indexed densely up to its current count. Released slots leave
        // `nil` entries but the size still tracks the highest allocated index + 1.
        countIncludingFreed
    }
}
