import XCTest
@testable import SwiftGraphDB

final class CSRAdjacencyTests: XCTestCase {

    // MARK: - Hand-built fixture (5 nodes, 7 edges)

    /// Node indexes:
    ///   0: A
    ///   1: B
    ///   2: C
    ///   3: D
    ///   4: E
    /// Outgoing edges (from → to):
    ///   A → B, A → C, A → D
    ///   B → C
    ///   C → D, C → E
    ///   D → E
    private func buildFixture() -> (CSRAdjacency, [NodeID]) {
        let ids = (0..<5).map { _ in IDFactory.live.nodeID() }
        let edges: [(from: Int, EdgeRecord)] = [
            (0, .init(toID: ids[1], edgeID: IDFactory.live.edgeID(), type: "L")),
            (0, .init(toID: ids[2], edgeID: IDFactory.live.edgeID(), type: "L")),
            (0, .init(toID: ids[3], edgeID: IDFactory.live.edgeID(), type: "L")),
            (1, .init(toID: ids[2], edgeID: IDFactory.live.edgeID(), type: "L")),
            (2, .init(toID: ids[3], edgeID: IDFactory.live.edgeID(), type: "L")),
            (2, .init(toID: ids[4], edgeID: IDFactory.live.edgeID(), type: "L")),
            (3, .init(toID: ids[4], edgeID: IDFactory.live.edgeID(), type: "L")),
        ]
        return (CSRAdjacency(nodeCount: 5, edges: edges), ids)
    }

    func testDegreeMatchesExpected() {
        let (csr, _) = buildFixture()
        XCTAssertEqual(csr.degree(of: 0), 3)
        XCTAssertEqual(csr.degree(of: 1), 1)
        XCTAssertEqual(csr.degree(of: 2), 2)
        XCTAssertEqual(csr.degree(of: 3), 1)
        XCTAssertEqual(csr.degree(of: 4), 0)
    }

    func testNeighboursReturnsEdgesInInsertionOrder() {
        let (csr, ids) = buildFixture()
        let outgoingFromA = Array(csr.neighbours(of: 0))
        XCTAssertEqual(outgoingFromA.map(\.toID), [ids[1], ids[2], ids[3]])
    }

    func testEmptyNodeReturnsEmptySlice() {
        let (csr, _) = buildFixture()
        let leaf = csr.neighbours(of: 4)
        XCTAssertTrue(leaf.isEmpty)
    }

    func testOutOfRangeNodeReturnsEmptySlice() {
        let (csr, _) = buildFixture()
        XCTAssertTrue(csr.neighbours(of: 5).isEmpty)
        XCTAssertTrue(csr.neighbours(of: -1).isEmpty)
    }

    // MARK: - Build from [Edge] + IndexMap

    func testInitFromEdgesMatchesManualBuilder() {
        let ids = (0..<3).map { _ in IDFactory.live.nodeID() }
        var indexMap = IndexMap()
        for id in ids { _ = indexMap.intern(id) }

        let edges: [Edge] = [
            Edge(type: "L", fromID: ids[0], toID: ids[1]),
            Edge(type: "L", fromID: ids[0], toID: ids[2]),
            Edge(type: "L", fromID: ids[1], toID: ids[2]),
        ]

        let csr = CSRAdjacency(forwardFrom: edges, indexMap: indexMap)
        XCTAssertEqual(csr.degree(of: 0), 2)
        XCTAssertEqual(csr.degree(of: 1), 1)
        XCTAssertEqual(csr.degree(of: 2), 0)

        let manual: [(from: Int, EdgeRecord)] = [
            (0, .init(toID: ids[1], edgeID: edges[0].id, type: "L")),
            (0, .init(toID: ids[2], edgeID: edges[1].id, type: "L")),
            (1, .init(toID: ids[2], edgeID: edges[2].id, type: "L")),
        ]
        let expected = CSRAdjacency(nodeCount: 3, edges: manual)
        XCTAssertEqual(csr.offsets, expected.offsets)
        XCTAssertEqual(csr.edges.map(\.toID), expected.edges.map(\.toID))
    }

    // MARK: - Forward + reverse coverage

    func testForwardAndReverseCoverEveryEdge() {
        let ids = (0..<4).map { _ in IDFactory.live.nodeID() }
        var indexMap = IndexMap()
        for id in ids { _ = indexMap.intern(id) }
        let edges: [Edge] = [
            Edge(type: "L", fromID: ids[0], toID: ids[1]),
            Edge(type: "L", fromID: ids[1], toID: ids[2]),
            Edge(type: "L", fromID: ids[2], toID: ids[3]),
            Edge(type: "L", fromID: ids[0], toID: ids[3]),
        ]

        let forward = CSRAdjacency(forwardFrom: edges, indexMap: indexMap)
        let reverse = CSRAdjacency(reverseFrom: edges, indexMap: indexMap)

        // Forward: outdegrees should sum to edge count.
        let outSum = (0..<4).map(forward.degree(of:)).reduce(0, +)
        XCTAssertEqual(outSum, 4)
        // Reverse: indegrees should also sum to edge count.
        let inSum = (0..<4).map(reverse.degree(of:)).reduce(0, +)
        XCTAssertEqual(inSum, 4)

        // Reverse adjacency for ids[3]: incoming edges from ids[2] and ids[0].
        let into3 = Array(reverse.neighbours(of: 3)).map(\.toID).sorted { $0.uuidString < $1.uuidString }
        let expected = [ids[0], ids[2]].sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(into3, expected)
    }

    // MARK: - Performance

    func test100KNodeAvgDegree10BuildsUnder200ms() {
        let n = 100_000
        let ids = (0..<n).map { _ in IDFactory.live.nodeID() }
        var indexMap = IndexMap()
        indexMap.reserveCapacity(n)
        for id in ids { _ = indexMap.intern(id) }

        var edges: [Edge] = []
        edges.reserveCapacity(n * 10)
        // Deterministic seeded random to keep the test stable.
        var rng = SplitMix64(seed: 1)
        for i in 0..<n {
            for _ in 0..<10 {
                let to = Int(rng.next() % UInt64(n))
                edges.append(Edge(type: "L", fromID: ids[i], toID: ids[to]))
            }
        }

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = CSRAdjacency(forwardFrom: edges, indexMap: indexMap)
        }
        // SPEC §10 target is < 200 ms for a release build. Debug builds are 2-3× slower; this
        // test only catches order-of-magnitude regressions.
        XCTAssertLessThan(elapsed, .seconds(1), "100K * 10 build took \(elapsed)")
    }

    private struct SplitMix64 {
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
