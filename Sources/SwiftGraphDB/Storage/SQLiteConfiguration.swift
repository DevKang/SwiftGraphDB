import Foundation

/// SQLite PRAGMA defaults applied on every open. SPEC §6.3.
///
/// The shipped values match the SPEC and are tuned for the embedded-graph workload (reasonable
/// durability, mmap-friendly read path). Apps with stricter durability needs can override
/// `synchronous`. Other knobs are intentionally not exposed yet — change them by editing this
/// file and running the benchmark suite.
public struct SQLiteConfiguration: Sendable {

    /// `PRAGMA synchronous`. Trade-off:
    /// - `.normal` (default): one fsync per WAL checkpoint; small chance of losing the last
    ///   transaction on a hard crash, but no risk of corruption.
    /// - `.full`: fsync per commit; matches a strict durability model at a write-throughput cost.
    /// - `.off`: no fsync; not recommended.
    public enum Synchronous: Int32, Sendable {
        case off = 0, normal = 1, full = 2, extra = 3
    }

    public var journalModeWAL: Bool
    public var synchronous: Synchronous
    public var tempStoreInMemory: Bool
    public var mmapSize: Int64
    public var cacheSizeKB: Int32 // negative value passed to PRAGMA cache_size = -N
    public var walAutocheckpoint: Int32

    public init(
        journalModeWAL: Bool = true,
        synchronous: Synchronous = .normal,
        tempStoreInMemory: Bool = true,
        mmapSize: Int64 = 134_217_728,
        cacheSizeKB: Int32 = 32_000,
        walAutocheckpoint: Int32 = 100
    ) {
        self.journalModeWAL = journalModeWAL
        self.synchronous = synchronous
        self.tempStoreInMemory = tempStoreInMemory
        self.mmapSize = mmapSize
        self.cacheSizeKB = cacheSizeKB
        self.walAutocheckpoint = walAutocheckpoint
    }

    public static let `default` = SQLiteConfiguration()
}
