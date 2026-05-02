import Foundation

/// Sync protocol version — independent of the SQLite schema. Bumped when a breaking change
/// to `GraphChange` serialisation lands.
public struct SyncProtocolVersion: Codable, Hashable, Sendable, Comparable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static let current = SyncProtocolVersion(major: 1, minor: 0)

    public static func < (lhs: SyncProtocolVersion, rhs: SyncProtocolVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }
}

/// Payload format version stamped onto every `GraphRecordPayload`. Adapters reject payloads
/// whose major version they don't understand.
public struct PayloadFormatVersion: Codable, Hashable, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static let current = PayloadFormatVersion(major: 1, minor: 0)
}
