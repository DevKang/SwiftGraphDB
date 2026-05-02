import XCTest
@testable import SwiftGraphDB

/// Three regression-gate XCTests that lock in headline numbers from SPEC §13. They run as
/// part of `swift test` so a 2× regression breaks the build. Generous ceilings keep them
/// stable on debug builds; release-mode runs of `swift test -c release` should clear the
/// SPEC §13 targets directly.
final class PerformanceBaselineTests: XCTestCase {

    /// Cold open + rebuild on a 10K-node graph.
    func testColdOpenRebuildBaseline() async throws {
        // Seed via bulk import.
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        let importer = BulkImporter(store: store)
        try importer.bulkInsert { batch in
            for i in 0..<10_000 {
                _ = batch.addNode(label: "P", properties: ["i": .int(Int64(i))])
            }
        }

        let (_, record) = try measureBenchmark("rebuild", scenario: "10k_nodes", nodes: 10_000) {
            _ = try RebuildFromSQLite.rebuild(store: store, propertyIndexSpecs: [])
        }
        // Debug ceiling: 1s (release should be well under 200ms).
        XCTAssertLessThan(record.elapsedNanos, 1_000_000_000)
    }

    /// 4-hop BFS on a 5K-node line graph.
    func testFourHopBFSBaseline() async throws {
        let graph = try await GraphStore.openInMemory()
        var ids: [NodeID] = []
        for _ in 0..<5_000 {
            ids.append(try await graph.addNode(label: "P"))
        }
        for i in 0..<4_999 {
            try await graph.addEdge(from: ids[i], to: ids[i + 1], type: "L")
        }

        let (_, record) = try await measureBenchmarkAsync("bfs", scenario: "4hop", nodes: 5_000) {
            try await graph.node(id: ids[0])
                .traverse(.outgoing, edge: "L", maxDepth: .bounded(4))
                .collect()
        }
        XCTAssertLessThan(record.elapsedNanos, 100_000_000) // 100ms generous debug ceiling
    }

    /// 5K-node bulk import. SPEC §13 target is 20K in 3s; we test a fraction so the
    /// regression test stays sub-second on debug.
    func testBulkImport5KNodesBaseline() throws {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        let importer = BulkImporter(store: store)
        let (_, record) = try measureBenchmark("bulk-import", scenario: "5k_nodes", nodes: 5_000) {
            try importer.bulkInsert { batch in
                for i in 0..<5_000 {
                    _ = batch.addNode(label: "P", properties: ["i": .int(Int64(i))])
                }
            }
        }
        XCTAssertLessThan(record.elapsedNanos, 1_000_000_000)
    }
}
