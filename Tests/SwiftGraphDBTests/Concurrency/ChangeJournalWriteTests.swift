import XCTest
@testable import SwiftGraphDB

final class ChangeJournalWriteTests: XCTestCase {

    private func makeActor() async throws -> GraphActor {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        return await GraphActor(store: store, propertyIndexSpecs: [])
    }

    // MARK: - addNode produces exactly one upsert row

    func testAddNodeWritesExactlyOneUpsertRow() async throws {
        let actor = try await makeActor()
        let id = try await actor.addNode(label: "Person", properties: ["name": "Alice"])

        let store = await actor.unsafeStoreForTests
        let journal = ChangeJournalStore(store: store)
        XCTAssertEqual(try journal.count(), 1)
        let row = try journal.latestRow(forEntity: .node, id: id)
        XCTAssertEqual(row?.entityKind, .node)
        XCTAssertEqual(row?.entityID, id)
        XCTAssertEqual(row?.operation, .upsert)
        XCTAssertNotNil(row?.payload)
    }

    // MARK: - updateNode records base_revision

    func testUpdateNodeRowCarriesBaseRevisionFromPriorRow() async throws {
        let actor = try await makeActor()
        let id = try await actor.addNode(label: "Person", properties: ["name": "Alice"])
        let store = await actor.unsafeStoreForTests
        let journal = ChangeJournalStore(store: store)
        let firstRev = try journal.latestRow(forEntity: .node, id: id)!.revision

        try await actor.updateNode(id: id, properties: ["name": "Alice2"])
        let secondRow = try journal.latestRow(forEntity: .node, id: id)!
        XCTAssertEqual(secondRow.baseRevision, firstRev)
        XCTAssertGreaterThan(secondRow.revision, firstRev)
    }

    // MARK: - deleteNode writes delete row and flips is_deleted

    func testDeleteNodeRecordsDeleteRowAndSoftDeletesEntity() async throws {
        let actor = try await makeActor()
        let id = try await actor.addNode(label: "Person", properties: [:])
        try await actor.deleteNode(id: id)

        let store = await actor.unsafeStoreForTests
        let journal = ChangeJournalStore(store: store)
        let last = try journal.latestRow(forEntity: .node, id: id)!
        XCTAssertEqual(last.operation, .delete)
        XCTAssertNil(last.payload)

        // Entity row still in table, but soft-deleted.
        let isDeleted = try store.query(
            "SELECT is_deleted FROM nodes WHERE id = ?",
            [.text(id.uuidString)]
        ) { $0.int(at: 0) ?? 0 }.first
        XCTAssertEqual(isDeleted, 1)
    }

    // MARK: - SQLite failure rolls back both writes

    func testSQLiteFailureLeavesNeitherEntityNorJournalRowBehind() async throws {
        let actor = try await makeActor()
        await actor.setFailureMode(.nextSQLiteWrite)

        do {
            _ = try await actor.addNode(label: "Person", properties: [:])
            XCTFail("expected throw")
        } catch {
            // expected
        }

        let store = await actor.unsafeStoreForTests
        let nodeCount = try store.query("SELECT COUNT(*) FROM nodes") { $0.int(at: 0) ?? 0 }.first
        let journalCount = try ChangeJournalStore(store: store).count()
        XCTAssertEqual(nodeCount, 0)
        XCTAssertEqual(journalCount, 0)
    }

    // MARK: - Concurrent addNode → strictly increasing per-actor counters

    func testConcurrentAddNodeProducesContiguousCounters() async throws {
        let actor = try await makeActor()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { _ = try await actor.addNode(label: "P", properties: [:]) }
            }
            try await group.waitForAll()
        }

        let store = await actor.unsafeStoreForTests
        let journal = ChangeJournalStore(store: store)
        let allRows = try journal.iterate(after: 0)
        XCTAssertEqual(allRows.count, 100)
        let counters = allRows.map { $0.revision.counter }.sorted()
        XCTAssertEqual(counters, Array(1...100), "counters must be 1..100 with no gaps or duplicates")
    }

    // MARK: - Reopen preserves counter monotonicity

    func testReopenContinuesCounterFromPriorMax() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftGraphDB-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("test.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var maxCounterFromFirstRun: Int64 = 0
        do {
            let store = try SQLiteStore(at: url)
            try MigrationRunner.runDefault(on: store)
            let actor = await GraphActor(store: store, propertyIndexSpecs: [])
            for _ in 0..<5 { _ = try await actor.addNode(label: "P", properties: [:]) }
            let journal = ChangeJournalStore(store: store)
            maxCounterFromFirstRun = try journal.iterate(after: 0).map(\.revision.counter).max() ?? 0
            store.close()
        }
        XCTAssertEqual(maxCounterFromFirstRun, 5)

        let store = try SQLiteStore(at: url)
        defer { store.close() }
        try MigrationRunner.runDefault(on: store)
        let actor = await GraphActor(store: store, propertyIndexSpecs: [])
        _ = try await actor.addNode(label: "P", properties: [:])
        let journal = ChangeJournalStore(store: store)
        let max = try journal.iterate(after: 0).map(\.revision.counter).max() ?? 0
        XCTAssertEqual(max, 6, "second run continues from prior max")
    }
}
