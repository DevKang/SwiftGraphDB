import Foundation

public typealias NodeID = UUID
public typealias EdgeID = UUID

/// Mints `NodeID` and `EdgeID` values.
///
/// All new node and edge IDs in the codebase must come from an `IDFactory` so tests can substitute a
/// deterministic instance. `UUID()` should not be called directly outside this file.
public struct IDFactory: Sendable {
    private let next: @Sendable () -> UUID

    /// Production factory backed by `UUID()` (cryptographically random).
    public static let live = IDFactory { UUID() }

    /// Deterministic factory for tests. Same seed produces the same sequence of IDs.
    public static func deterministic(seed: UInt64) -> IDFactory {
        let state = SplitMix64State(seed: seed)
        return IDFactory { state.nextUUID() }
    }

    private init(_ next: @escaping @Sendable () -> UUID) {
        self.next = next
    }

    public func nodeID() -> NodeID { next() }
    public func edgeID() -> EdgeID { next() }
}

/// SplitMix64 PRNG, wrapped in a class so the captured closure can mutate state.
/// Reference: Steele, Lea, Flood (2014). Used purely for deterministic test fixtures.
private final class SplitMix64State: @unchecked Sendable {
    private var state: UInt64
    private let lock = NSLock()

    init(seed: UInt64) { self.state = seed }

    private func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }

    func nextUUID() -> UUID {
        let hi = next()
        let lo = next()
        let bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
            UInt8(truncatingIfNeeded: hi >> 56),
            UInt8(truncatingIfNeeded: hi >> 48),
            UInt8(truncatingIfNeeded: hi >> 40),
            UInt8(truncatingIfNeeded: hi >> 32),
            UInt8(truncatingIfNeeded: hi >> 24),
            UInt8(truncatingIfNeeded: hi >> 16),
            UInt8(truncatingIfNeeded: hi >> 8),
            UInt8(truncatingIfNeeded: hi),
            UInt8(truncatingIfNeeded: lo >> 56),
            UInt8(truncatingIfNeeded: lo >> 48),
            UInt8(truncatingIfNeeded: lo >> 40),
            UInt8(truncatingIfNeeded: lo >> 32),
            UInt8(truncatingIfNeeded: lo >> 24),
            UInt8(truncatingIfNeeded: lo >> 16),
            UInt8(truncatingIfNeeded: lo >> 8),
            UInt8(truncatingIfNeeded: lo)
        )
        return UUID(uuid: bytes)
    }
}
