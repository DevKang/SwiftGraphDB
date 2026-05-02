import Foundation

public struct EdgeLogEntry: Sendable, Equatable {
    public let edgeID: EdgeID
    public let fromID: NodeID
    public let toID: NodeID
    public let type: String
    public let revision: GraphRevision
    public let operation: GraphOperation

    public init(
        edgeID: EdgeID,
        fromID: NodeID,
        toID: NodeID,
        type: String,
        revision: GraphRevision,
        operation: GraphOperation
    ) {
        self.edgeID = edgeID
        self.fromID = fromID
        self.toID = toID
        self.type = type
        self.revision = revision
        self.operation = operation
    }
}

/// Append-only buffer of recent edge mutations, merged with CSR at read time.
///
/// SPEC §5.3. CSR is fast to read but slow to mutate, so writes accumulate in `EdgeLog` and the
/// graph actor periodically compacts them into a fresh CSR (OML-1933).
///
/// Reads merge per-source-node CSR slices with the log entries that touch that node:
/// - newer log entries shadow older CSR records sharing the same `edgeID`,
/// - `.delete` log entries suppress matching CSR records.
///
/// This file owns both the data structure (append, query) and the merge function — `merge` is a
/// pure static function so the BFS traversal in M5 can call it from a snapshot, off-actor.
public struct EdgeLog: Sendable {

    private(set) var entries: [EdgeLogEntry] = []
    private var byFrom: [NodeID: [Int]] = [:] // value: indices into `entries`
    private var byTo: [NodeID: [Int]] = [:]

    public init() {}

    public var size: Int { entries.count }

    public var isEmpty: Bool { entries.isEmpty }

    /// Append an entry. O(1).
    public mutating func append(_ entry: EdgeLogEntry) {
        let idx = entries.count
        entries.append(entry)
        byFrom[entry.fromID, default: []].append(idx)
        byTo[entry.toID, default: []].append(idx)
    }

    /// All log entries whose `fromID` equals the argument, in append order.
    public func outgoingEntries(from id: NodeID) -> [EdgeLogEntry] {
        guard let indices = byFrom[id] else { return [] }
        return indices.map { entries[$0] }
    }

    /// All log entries whose `toID` equals the argument, in append order.
    public func incomingEntries(to id: NodeID) -> [EdgeLogEntry] {
        guard let indices = byTo[id] else { return [] }
        return indices.map { entries[$0] }
    }

    /// Merge a CSR slice for one source node with the corresponding log entries. Returns the
    /// effective list of live `EdgeRecord`s after applying log shadowing and deletes.
    public static func merge(
        csrEdges: ArraySlice<EdgeRecord>,
        logEntries: [EdgeLogEntry]
    ) -> [EdgeRecord] {
        if logEntries.isEmpty { return Array(csrEdges) }

        // Resolve each edge id to its final state. The "newer" entry wins per `GraphRevision`
        // ordering — same-actor entries fall back to counter (matches OML-1932 behaviour);
        // cross-actor entries use wallClock + actorID. We remember the *first* index per id so
        // pass 2 can emit log-only inserts in stable order even when revisions don't.
        var finalState: [EdgeID: EdgeLogEntry] = [:]
        var firstSeen: [EdgeID: Int] = [:]
        for (i, entry) in logEntries.enumerated() {
            if let existing = finalState[entry.edgeID] {
                if existing.revision < entry.revision {
                    finalState[entry.edgeID] = entry
                }
            } else {
                finalState[entry.edgeID] = entry
                firstSeen[entry.edgeID] = i
            }
        }

        // Pass 1: keep CSR edges that are not deleted or replaced.
        var output: [EdgeRecord] = []
        output.reserveCapacity(csrEdges.count + logEntries.count)
        var consumed: Set<EdgeID> = []
        for record in csrEdges {
            if let resolved = finalState[record.edgeID] {
                consumed.insert(record.edgeID)
                if resolved.operation == .upsert {
                    output.append(EdgeRecord(
                        toID: resolved.toID, edgeID: resolved.edgeID, type: resolved.type
                    ))
                }
                // .delete suppresses the CSR edge entirely.
            } else {
                output.append(record)
            }
        }

        // Pass 2: append remaining log inserts that didn't shadow a CSR edge, in stable order
        // of first-appearance in the log.
        let remainingInserts: [EdgeLogEntry] = finalState.values
            .filter { $0.operation == .upsert && !consumed.contains($0.edgeID) }
            .sorted { (firstSeen[$0.edgeID] ?? .max) < (firstSeen[$1.edgeID] ?? .max) }

        for entry in remainingInserts {
            output.append(EdgeRecord(toID: entry.toID, edgeID: entry.edgeID, type: entry.type))
        }

        return output
    }
}
