import Foundation

/// Stable identifier for one local store / device. Stamped once into `db_meta.actor_id` on the
/// first M4½ open and reused for every revision minted by that store.
public typealias ActorID = UUID

/// Globally unique identifier for a `GraphChange`. M8 wraps the durable `change_journal.change_id`.
public typealias ChangeID = UUID

/// Identifier for the local graph (matches `db_meta.graph_id`). Used by `GraphChange` so a sync
/// receiver can attribute incoming changes to the right graph.
public typealias GraphID = UUID

/// Identifier for one configured sync backend (`"cloudkit-private"`, `"rest-main"`, …).
/// Adapter packages choose their own conventions; core treats it as opaque.
public struct SyncBackendID: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }
}
