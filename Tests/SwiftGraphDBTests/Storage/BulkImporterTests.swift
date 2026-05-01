import XCTest
@testable import SwiftGraphDB

final class BulkImporterTests: XCTestCase {

    // MARK: - Happy path

    func testBulkInsertOfNodesAndEdges() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }
        try MigrationRunner.runDefault(on: store)

        let importer = BulkImporter(store: store)
        let summary = try importer.bulkInsert { batch in
            var ids: [NodeID] = []
            for i in 0..<1000 {
                let id = batch.addNode(label: "Person", properties: ["i": .int(Int64(i))])
                ids.append(id)
            }
            // Star: every node 1..N connects to node 0.
            for id in ids.dropFirst() {
                _ = batch.addEdge(from: ids[0], to: id, type: "KNOWS")
            }
        }

        XCTAssertEqual(summary.nodesInserted, 1000)
        XCTAssertEqual(summary.edgesInserted, 999)

        let nodeCount = try store.query("SELECT COUNT(*) FROM nodes WHERE is_deleted = 0") { $0.int(at: 0)! }.first
        XCTAssertEqual(nodeCount, 1000)
        let edgeCount = try store.query("SELECT COUNT(*) FROM edges WHERE is_deleted = 0") { $0.int(at: 0)! }.first
        XCTAssertEqual(edgeCount, 999)
    }

    // MARK: - Closure-throw rolls everything back

    func testThrowingClosureRollsBackEntireBatch() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }
        try MigrationRunner.runDefault(on: store)

        let importer = BulkImporter(store: store)
        struct Boom: Error {}
        XCTAssertThrowsError(
            try importer.bulkInsert { batch in
                _ = batch.addNode(label: "Person", properties: ["name": "Alice"])
                _ = batch.addNode(label: "Person", properties: ["name": "Bob"])
                throw Boom()
            }
        )

        let nodeCount = try store.query("SELECT COUNT(*) FROM nodes") { $0.int(at: 0)! }.first ?? -1
        XCTAssertEqual(nodeCount, 0, "rollback should have left no nodes behind")
    }

    // MARK: - addNode returns ids usable by addEdge

    func testAddNodeReturnsIDForUseByAddEdge() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }
        try MigrationRunner.runDefault(on: store)

        let importer = BulkImporter(store: store)
        var alice: NodeID = UUID()
        var bob: NodeID = UUID()
        try importer.bulkInsert { batch in
            alice = batch.addNode(label: "Person", properties: ["name": "Alice"])
            bob = batch.addNode(label: "Person", properties: ["name": "Bob"])
            _ = batch.addEdge(from: alice, to: bob, type: "KNOWS")
        }

        let edges = EdgeRepository(store: store)
        let outgoing = try edges.fetchOutgoing(from: alice, type: "KNOWS")
        XCTAssertEqual(outgoing.count, 1)
        XCTAssertEqual(outgoing.first?.toID, bob)
    }

    // MARK: - Batch handle scope

    func testBatchHandleIsRejectedAfterClosureReturns() throws {
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }
        try MigrationRunner.runDefault(on: store)

        let importer = BulkImporter(store: store)
        var captured: BulkImporter.Batch?
        try importer.bulkInsert { batch in
            captured = batch
        }
        XCTAssertNotNil(captured)
        // After the closure has returned, the batch is no longer usable.
        XCTAssertThrowsError(try captured!.addNodeStrict(label: "Person", properties: [:]))
    }

    // MARK: - Throughput baseline

    func testBulkInsert20KNodesUnderPerfBudget() throws {
        // PERF: SPEC §10 target — 20K nodes in under 3 seconds. Run loosely; CI may differ.
        let store = try SQLiteStore.openInMemory()
        defer { store.close() }
        try MigrationRunner.runDefault(on: store)

        let clock = ContinuousClock()
        let importer = BulkImporter(store: store)
        let elapsed = try clock.measure {
            try importer.bulkInsert { batch in
                for i in 0..<20_000 {
                    _ = batch.addNode(label: "P", properties: ["i": .int(Int64(i))])
                }
            }
        }

        XCTAssertLessThan(elapsed, .seconds(3), "20K node insert should fit SPEC §10 budget; was \(elapsed)")
    }
}
