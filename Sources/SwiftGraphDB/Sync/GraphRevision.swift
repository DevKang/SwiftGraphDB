import Foundation

/// Logical revision of a node or edge.
///
/// SPEC §3.5. A revision is a `(actorID, counter, wallClock)` triple. It serves three purposes:
/// 1. orders mutations from the same actor monotonically (`counter`),
/// 2. resolves cross-actor ties for sync conflict detection (`wallClock`, then `actorID`),
/// 3. tags every `change_journal` row so adapters can checkpoint without inventing identifiers.
///
/// **Comparable semantics are not distributed causal ordering.** Two revisions from different
/// actors compare by wall-clock then `actorID.uuidString`. Vector clocks are SPEC §17.2; until
/// they land, callers should treat cross-actor ordering as a deterministic but app-level
/// tiebreak rather than a causal-precedes relationship.
public struct GraphRevision: Codable, Hashable, Sendable, Comparable {
    public let actorID: ActorID
    public let counter: Int64
    public let wallClock: Date

    public init(actorID: ActorID, counter: Int64, wallClock: Date) {
        self.actorID = actorID
        self.counter = counter
        self.wallClock = wallClock
    }

    public static func < (lhs: GraphRevision, rhs: GraphRevision) -> Bool {
        if lhs.actorID == rhs.actorID {
            return lhs.counter < rhs.counter
        }
        if lhs.wallClock != rhs.wallClock {
            return lhs.wallClock < rhs.wallClock
        }
        return lhs.actorID.uuidString < rhs.actorID.uuidString
    }

    /// Sentinel value used by `Node` / `Edge` defaults before the actor stamps a real revision.
    /// `actorID = .zero`, `counter = 0`. `wallClock` is the construction time.
    public static func placeholder(wallClock: Date = Date()) -> GraphRevision {
        GraphRevision(
            actorID: ActorID(uuid: (0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0)),
            counter: 0,
            wallClock: wallClock
        )
    }
}

/// Operation tag carried on `EdgeLogEntry`, `change_journal`, and `GraphChange`.
public enum GraphOperation: String, Codable, Sendable, Hashable {
    case upsert
    case delete
}
