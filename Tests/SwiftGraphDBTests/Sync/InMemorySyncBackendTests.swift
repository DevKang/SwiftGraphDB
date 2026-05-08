import XCTest
@testable import SwiftGraphDB

final class InMemorySyncBackendTests: XCTestCase {

    private func makeChange(actorID: ActorID, sequence: Int64) -> GraphChange {
        GraphChange(
            id: UUID(),
            graphID: UUID(),
            actorID: actorID,
            sequence: sequence,
            entity: GraphEntityRef(kind: .node, id: UUID()),
            operation: .upsert,
            payload: GraphRecordPayload(properties: ["x": .int(sequence)], label: "P"),
            baseRevision: nil,
            revision: GraphRevision(actorID: actorID, counter: sequence, wallClock: Date()),
            createdAt: Date()
        )
    }

    func testPushAcceptsAllChangesAndReturnsCheckpoint() async throws {
        let backend = InMemorySyncBackend()
        let device = SyncBackendID(UUID().uuidString)
        let actor = UUID()
        let transport = await backend.transport(for: device)

        let batch = ChangeBatch(
            graphID: UUID(),
            backendID: device,
            changes: [makeChange(actorID: actor, sequence: 1), makeChange(actorID: actor, sequence: 2)],
            highWatermark: 0
        )
        let result = try await transport.push(batch)
        XCTAssertEqual(result.accepted.count, 2)
        XCTAssertNotNil(result.checkpoint)
    }

    func testPullReturnsChangesFromOtherDevicesOnly() async throws {
        let backend = InMemorySyncBackend()
        let actorA = UUID()
        let actorB = UUID()
        let deviceA = SyncBackendID(actorA.uuidString)
        let deviceB = SyncBackendID(actorB.uuidString)
        let transportA = await backend.transport(for: deviceA)
        let transportB = await backend.transport(for: deviceB)

        let aChange = makeChange(actorID: actorA, sequence: 1)
        _ = try await transportA.push(.init(graphID: UUID(), backendID: deviceA, changes: [aChange], highWatermark: 0))

        // Device A pulls — does not see its own change.
        let aPull = try await transportA.pull(since: nil)
        XCTAssertTrue(aPull.changes.isEmpty)

        // Device B pulls — sees A's change.
        let bPull = try await transportB.pull(since: nil)
        XCTAssertEqual(bPull.changes.map(\.id), [aChange.id])
    }

    func testIdempotentPushDoesNotDuplicate() async throws {
        let backend = InMemorySyncBackend()
        let device = SyncBackendID(UUID().uuidString)
        let actor = UUID()
        let transport = await backend.transport(for: device)
        let change = makeChange(actorID: actor, sequence: 1)
        let batch = ChangeBatch(graphID: UUID(), backendID: device, changes: [change], highWatermark: 0)
        _ = try await transport.push(batch)
        _ = try await transport.push(batch) // re-push
        let count = await backend.changeCount
        XCTAssertEqual(count, 1)
    }

    func testCheckpointResume() async throws {
        let backend = InMemorySyncBackend()
        let actorA = UUID()
        let actorB = UUID()
        let deviceA = SyncBackendID(actorA.uuidString)
        let deviceB = SyncBackendID(actorB.uuidString)
        let transportA = await backend.transport(for: deviceA)
        let transportB = await backend.transport(for: deviceB)

        let firstChange = makeChange(actorID: actorA, sequence: 1)
        _ = try await transportA.push(.init(graphID: UUID(), backendID: deviceA, changes: [firstChange], highWatermark: 0))
        let firstPull = try await transportB.pull(since: nil)
        XCTAssertEqual(firstPull.changes.count, 1)

        // Push another change while B is paused.
        let secondChange = makeChange(actorID: actorA, sequence: 2)
        _ = try await transportA.push(.init(graphID: UUID(), backendID: deviceA, changes: [secondChange], highWatermark: 0))

        // Resume from B's checkpoint — only the new change.
        let resume = try await transportB.pull(since: firstPull.checkpoint)
        XCTAssertEqual(resume.changes.map(\.id), [secondChange.id])
    }

    func testInjectedTransientPushRejection() async throws {
        let backend = InMemorySyncBackend()
        let device = SyncBackendID(UUID().uuidString)
        let actor = UUID()
        let transport = await backend.transport(for: device)
        await backend.setFailureMode(.nextPushTransient)
        let change = makeChange(actorID: actor, sequence: 1)
        let result = try await transport.push(.init(graphID: UUID(), backendID: device, changes: [change], highWatermark: 0))
        XCTAssertEqual(result.accepted.count, 0)
        XCTAssertEqual(result.rejected.count, 1)
        if case .transient = result.rejected[0].reason {} else {
            XCTFail("expected .transient")
        }
    }

    func testPullWithStaleCheckpointDoesNotCrash() async throws {
        // Simulate: push changes to backend A, get a checkpoint with cursor=2,
        // then create a NEW backend B (empty log) and pull with the stale checkpoint.
        // Before the fix this crashed with "Range requires lowerBound <= upperBound".
        let backendA = InMemorySyncBackend()
        let actor = UUID()
        let device = SyncBackendID(actor.uuidString)
        let transportA = await backendA.transport(for: device)

        let changes = [makeChange(actorID: actor, sequence: 1), makeChange(actorID: actor, sequence: 2)]
        let pushResult = try await transportA.push(.init(graphID: UUID(), backendID: device, changes: changes, highWatermark: 0))
        let staleCheckpoint = pushResult.checkpoint

        // New backend with empty log — stale cursor (2) exceeds log.count (0).
        let backendB = InMemorySyncBackend()
        let transportB = await backendB.transport(for: device)
        let pullResult = try await transportB.pull(since: staleCheckpoint)
        XCTAssertTrue(pullResult.changes.isEmpty)
        XCTAssertNotNil(pullResult.checkpoint)
    }

    func testInjectedTransientPullThrows() async throws {
        let backend = InMemorySyncBackend()
        let device = SyncBackendID(UUID().uuidString)
        let transport = await backend.transport(for: device)
        await backend.setFailureMode(.nextPullTransient)
        do {
            _ = try await transport.pull(since: nil)
            XCTFail("expected throw")
        } catch InMemorySyncError.injectedTransient {
            // ok
        }
    }
}
