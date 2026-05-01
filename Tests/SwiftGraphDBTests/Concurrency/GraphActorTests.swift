import XCTest
@testable import SwiftGraphDB

final class GraphActorTests: XCTestCase {

    // MARK: - Helpers

    private func makeActor(specs: [PropertyIndexSpec] = []) async throws -> GraphActor {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        return await GraphActor(store: store, propertyIndexSpecs: specs)
    }

    // MARK: - Sequential addNode returns distinct ids

    func testSequentialAddNodeReturnsDistinctIDs() async throws {
        let actor = try await makeActor()
        var seen = Set<NodeID>()
        for _ in 0..<100 {
            let id = try await actor.addNode(label: "Person", properties: [:])
            seen.insert(id)
        }
        XCTAssertEqual(seen.count, 100)
    }

    // MARK: - addNode populates label index synchronously

    func testAddNodeUpdatesLabelIndexSynchronously() async throws {
        let actor = try await makeActor()
        let id = try await actor.addNode(label: "Person", properties: ["name": "Alice"])
        let labelIDs = await actor.labelIndexNodes(labeled: "Person")
        XCTAssertEqual(labelIDs, [id])
    }

    // MARK: - addNode persists to SQLite

    func testAddNodePersistsToSQLite() async throws {
        let actor = try await makeActor()
        let id = try await actor.addNode(label: "Person", properties: ["name": "Alice"])
        let store = await actor.unsafeStoreForTests
        let nodes = NodeRepository(store: store)
        XCTAssertEqual(try nodes.fetch(id: id)?.label, "Person")
    }

    // MARK: - addEdge wires both directions

    func testAddEdgeIsVisibleViaCSRPlusLogMerge() async throws {
        let actor = try await makeActor()
        let from = try await actor.addNode(label: "Person", properties: ["name": "A"])
        let to = try await actor.addNode(label: "Person", properties: ["name": "B"])
        _ = try await actor.addEdge(from: from, to: to, type: "KNOWS", properties: [:])

        // Edges live in the EdgeLog until compaction; the merge function (used by traversal in
        // M5) is what the user-visible read path observes.
        let snapshot = await actor.snapshotForTests()
        let fromIndex = snapshot.indexMap.internalIndex(for: from)!
        let merged = EdgeLog.merge(
            csrEdges: snapshot.forward.neighbours(of: fromIndex),
            logEntries: snapshot.edgeLog.outgoingEntries(from: from)
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.toID, to)
    }

    // MARK: - Concurrent addEdge from detached tasks

    func testConcurrentAddEdgesFromDetachedTasksConverge() async throws {
        let actor = try await makeActor()
        let from = try await actor.addNode(label: "Person", properties: [:])
        var receivers: [NodeID] = []
        for _ in 0..<50 {
            receivers.append(try await actor.addNode(label: "Person", properties: [:]))
        }

        // Fire 50 concurrent addEdge calls.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for receiver in receivers {
                group.addTask { [actor] in
                    _ = try await actor.addEdge(from: from, to: receiver, type: "KNOWS", properties: [:])
                }
            }
            try await group.waitForAll()
        }

        let snapshot = await actor.snapshotForTests()
        let i = snapshot.indexMap.internalIndex(for: from)!
        let merged = EdgeLog.merge(
            csrEdges: snapshot.forward.neighbours(of: i),
            logEntries: snapshot.edgeLog.outgoingEntries(from: from)
        )
        XCTAssertEqual(merged.count, 50)
    }

    // MARK: - SQLite failure rolls back: nothing in either layer

    func testSQLiteFailureLeavesNothingInEitherLayer() async throws {
        let actor = try await makeActor()
        await actor.setFailureMode(.nextSQLiteWrite)

        do {
            _ = try await actor.addNode(label: "Person", properties: [:])
            XCTFail("expected throw")
        } catch {
            // expected
        }

        let snapshot = await actor.snapshotForTests()
        XCTAssertEqual(snapshot.indexMap.count, 0)
        let store = await actor.unsafeStoreForTests
        let count = try store.query("SELECT COUNT(*) FROM nodes") { $0.int(at: 0)! }.first ?? -1
        XCTAssertEqual(count, 0, "SQLite should be empty after rollback")
    }

    // MARK: - In-memory failure triggers rebuild; SQLite remains source of truth

    func testInMemoryFailureRebuildsAndKeepsRowQueryable() async throws {
        let actor = try await makeActor()

        // Pre-seed: one node so rebuild has work to do.
        let pre = try await actor.addNode(label: "Person", properties: ["name": "Pre"])

        // Inject a failure on the next in-memory update.
        await actor.setFailureMode(.nextInMemoryUpdate)

        // Caller should NOT observe an error: the actor catches the in-memory throw,
        // rebuilds from SQLite (source of truth), and reports success.
        let post = try await actor.addNode(label: "Person", properties: ["name": "Post"])

        let snapshot = await actor.snapshotForTests()
        XCTAssertNotNil(snapshot.indexMap.internalIndex(for: pre))
        XCTAssertNotNil(snapshot.indexMap.internalIndex(for: post))
        XCTAssertEqual(snapshot.labelIndex.nodes(labeled: "Person").count, 2)
    }

    // MARK: - update / delete

    func testUpdateNodeMergesProperties() async throws {
        let actor = try await makeActor()
        let id = try await actor.addNode(label: "Person", properties: ["name": "A", "age": 30])
        try await actor.updateNode(id: id, properties: ["age": 31])

        let store = await actor.unsafeStoreForTests
        let n = try NodeRepository(store: store).fetch(id: id)
        XCTAssertEqual(n?.properties["name"], "A")
        XCTAssertEqual(n?.properties["age"], 31)
    }

    func testDeleteNodeSoftDeletes() async throws {
        let actor = try await makeActor()
        let id = try await actor.addNode(label: "Person", properties: [:])
        try await actor.deleteNode(id: id)

        let snapshot = await actor.snapshotForTests()
        XCTAssertEqual(snapshot.labelIndex.nodes(labeled: "Person"), [])
        let store = await actor.unsafeStoreForTests
        let n = try NodeRepository(store: store).fetch(id: id)
        XCTAssertNil(n)
    }
}
