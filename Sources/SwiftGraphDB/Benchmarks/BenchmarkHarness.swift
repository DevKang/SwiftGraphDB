import Foundation

/// Reproducible synthetic graph builders for benchmarks. Each generator is deterministic for
/// a given `seed` so a "before" and "after" run produce identical fixtures.
///
/// Used by `Benchmarks/baseline.md` regression coverage in OML-1948 and by adapter authors
/// who want to exercise the SPEC §13 latency targets without writing their own dataset.
public enum BenchmarkFixtures {

    /// Returns N nodes with no edges. Useful for cold-rebuild and bulk-import benchmarks.
    public static func nodes(count: Int, label: String = "P") -> [Node] {
        (0..<count).map { i in
            Node(id: deterministicNodeID(seed: 1, index: i),
                 label: label,
                 properties: ["i": .int(Int64(i))])
        }
    }

    /// Line graph: N nodes and N-1 edges connecting them in order.
    public static func lineGraph(count: Int) -> (nodes: [Node], edges: [(NodeID, NodeID)]) {
        let ns = nodes(count: count)
        var edges: [(NodeID, NodeID)] = []
        edges.reserveCapacity(max(0, count - 1))
        for i in 0..<max(0, count - 1) {
            edges.append((ns[i].id, ns[i + 1].id))
        }
        return (ns, edges)
    }

    /// Random graph with a fixed average outdegree. Deterministic for a given `seed`.
    public static func randomGraph(
        nodeCount: Int,
        averageDegree: Int,
        seed: UInt64
    ) -> (nodes: [Node], edges: [(NodeID, NodeID)]) {
        let ns = nodes(count: nodeCount)
        var rng = SplitMix64(seed: seed)
        var edges: [(NodeID, NodeID)] = []
        edges.reserveCapacity(nodeCount * averageDegree)
        for from in 0..<nodeCount {
            for _ in 0..<averageDegree {
                let to = Int(rng.next() % UInt64(nodeCount))
                edges.append((ns[from].id, ns[to].id))
            }
        }
        return (ns, edges)
    }

    private static func deterministicNodeID(seed: UInt64, index: Int) -> NodeID {
        // Two SplitMix64 draws → 16 bytes → UUID. Seeded so the same (seed, index) always
        // yields the same id.
        var rng = SplitMix64(seed: seed &+ UInt64(index) &* 0x9E37_79B9_7F4A_7C15)
        let hi = rng.next()
        let lo = rng.next()
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
        return NodeID(uuid: bytes)
    }

    struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z &>> 31)
        }
    }
}

/// One entry in the harness JSON output. Adapter authors append rows from inside their tests.
public struct BenchmarkResult: Codable, Sendable {
    public let name: String
    public let scenario: String
    public let elapsedNanos: UInt64
    public let nodes: Int
    public let edges: Int
    public let extra: [String: String]

    public init(
        name: String,
        scenario: String,
        elapsed: Duration,
        nodes: Int = 0,
        edges: Int = 0,
        extra: [String: String] = [:]
    ) {
        self.name = name
        self.scenario = scenario
        // Convert Duration → nanos.
        let comps = elapsed.components
        self.elapsedNanos = UInt64(comps.seconds) * 1_000_000_000
            + UInt64(comps.attoseconds / 1_000_000_000)
        self.nodes = nodes
        self.edges = edges
        self.extra = extra
    }
}

/// Time a synchronous block once and return a `BenchmarkResult`.
public func measureBenchmark<T>(
    _ name: String,
    scenario: String,
    nodes: Int = 0,
    edges: Int = 0,
    body: () throws -> T
) rethrows -> (result: T, record: BenchmarkResult) {
    let clock = ContinuousClock()
    var output: T!
    let elapsed = try clock.measure { output = try body() }
    let record = BenchmarkResult(name: name, scenario: scenario, elapsed: elapsed, nodes: nodes, edges: edges)
    return (output, record)
}

public func measureBenchmarkAsync<T>(
    _ name: String,
    scenario: String,
    nodes: Int = 0,
    edges: Int = 0,
    body: () async throws -> T
) async rethrows -> (result: T, record: BenchmarkResult) {
    let clock = ContinuousClock()
    let start = clock.now
    let output = try await body()
    let elapsed = clock.now - start
    let record = BenchmarkResult(name: name, scenario: scenario, elapsed: elapsed, nodes: nodes, edges: edges)
    return (output, record)
}
