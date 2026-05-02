import XCTest
@testable import SwiftGraphDB

final class BenchmarkHarnessTests: XCTestCase {

    func testNodesGeneratorIsDeterministic() {
        let a = BenchmarkFixtures.nodes(count: 100)
        let b = BenchmarkFixtures.nodes(count: 100)
        XCTAssertEqual(a.map(\.id), b.map(\.id))
    }

    func testLineGraphHasN_NodesAndN_Minus_1Edges() {
        let (nodes, edges) = BenchmarkFixtures.lineGraph(count: 50)
        XCTAssertEqual(nodes.count, 50)
        XCTAssertEqual(edges.count, 49)
        XCTAssertEqual(edges.first?.0, nodes[0].id)
        XCTAssertEqual(edges.first?.1, nodes[1].id)
        XCTAssertEqual(edges.last?.1, nodes[49].id)
    }

    func testRandomGraphIsDeterministicForSeed() {
        let (n1, e1) = BenchmarkFixtures.randomGraph(nodeCount: 100, averageDegree: 4, seed: 42)
        let (n2, e2) = BenchmarkFixtures.randomGraph(nodeCount: 100, averageDegree: 4, seed: 42)
        XCTAssertEqual(n1.map(\.id), n2.map(\.id))
        XCTAssertEqual(e1.map { "\($0.0)-\($0.1)" }, e2.map { "\($0.0)-\($0.1)" })
        XCTAssertEqual(e1.count, 400)
    }

    func testMeasureBenchmarkRecordsElapsed() {
        let (_, record) = measureBenchmark("test", scenario: "noop") {
            return 42
        }
        XCTAssertEqual(record.name, "test")
        XCTAssertEqual(record.scenario, "noop")
        XCTAssertGreaterThan(record.elapsedNanos, 0)
    }

    func testBenchmarkResultRoundTripsThroughJSON() throws {
        let r = BenchmarkResult(name: "open", scenario: "fresh", elapsed: .milliseconds(12), nodes: 100, edges: 50)
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(BenchmarkResult.self, from: data)
        XCTAssertEqual(decoded.name, "open")
        XCTAssertEqual(decoded.elapsedNanos, 12_000_000)
        XCTAssertEqual(decoded.nodes, 100)
    }
}
