import XCTest
@testable import SwiftGraphDB
@testable import SwiftGraphDBCloudKit

final class CloudKitBatchAndBackoffTests: XCTestCase {

    // MARK: - Test clock

    /// Records every requested sleep duration without actually sleeping.
    actor RecordingClock: TransportClock {
        private(set) var sleeps: [TimeInterval] = []
        nonisolated func sleep(seconds: TimeInterval) async throws {
            await record(seconds)
        }
        private func record(_ s: TimeInterval) { sleeps.append(s) }
        func snapshot() -> [TimeInterval] { sleeps }
    }

    // MARK: - Fixtures

    private func makeChange(sequence: Int64 = 1) -> GraphChange {
        let actor = ActorID()
        return GraphChange(
            id: UUID(), graphID: UUID(), actorID: actor,
            sequence: sequence,
            entity: GraphEntityRef(kind: .node, id: UUID()),
            operation: .upsert,
            payload: GraphRecordPayload(properties: ["i": .int(sequence)], label: "P"),
            baseRevision: nil,
            revision: GraphRevision(actorID: actor, counter: sequence, wallClock: Date()),
            createdAt: Date()
        )
    }

    private func makeBatch(_ changes: [GraphChange]) -> ChangeBatch {
        ChangeBatch(graphID: UUID(), backendID: SyncBackendID("dev"), changes: changes, highWatermark: 0)
    }

    // MARK: - Chunking by config cap

    func testBatchOver600IsChunkedIntoTwo300sByDefault() async throws {
        let mock = MockCloudKitDatabase()
        let transport = CloudKitGraphSyncTransport(
            backendID: SyncBackendID("dev"),
            database: mock,
            configuration: .init(maxBatchSize: 300, clock: RecordingClock())
        )
        let changes = (1...600).map { makeChange(sequence: Int64($0)) }
        let result = try await transport.push(makeBatch(changes))

        XCTAssertEqual(result.accepted.count, 600)
        let count = await mock.saveCallCount
        XCTAssertEqual(count, 2)
        let history = await mock.saveCallSavedHistory
        XCTAssertEqual(history[0].count, 300)
        XCTAssertEqual(history[1].count, 300)
    }

    // MARK: - limitExceeded → split

    func testLimitExceededSplitsBatchInHalf() async throws {
        let mock = MockCloudKitDatabase()
        // First call fails with limitExceeded; subsequent calls succeed (the two halves).
        await mock.queueSaveErrors([.limitExceeded])

        let transport = CloudKitGraphSyncTransport(
            backendID: SyncBackendID("dev"),
            database: mock,
            // Use a large cap so splitting is driven by limitExceeded, not chunking.
            configuration: .init(maxBatchSize: 10_000, clock: RecordingClock())
        )
        let changes = (1...4).map { makeChange(sequence: Int64($0)) }
        let result = try await transport.push(makeBatch(changes))

        XCTAssertEqual(result.accepted.count, 4)
        let count = await mock.saveCallCount
        // 1 failed call + 2 succeeded halves = 3 modify invocations total.
        XCTAssertEqual(count, 3)
        let history = await mock.saveCallSavedHistory
        XCTAssertEqual(history[0].count, 4)   // initial attempt
        XCTAssertEqual(history[1].count, 2)   // first half retry
        XCTAssertEqual(history[2].count, 2)   // second half retry
    }

    func testLimitExceededOnSingleRecordSurfacesAsTransient() async throws {
        let mock = MockCloudKitDatabase()
        await mock.queueSaveErrors([.limitExceeded])

        let transport = CloudKitGraphSyncTransport(
            backendID: SyncBackendID("dev"),
            database: mock,
            configuration: .init(maxBatchSize: 10_000, clock: RecordingClock())
        )
        let result = try await transport.push(makeBatch([makeChange()]))
        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.rejected.count, 1)
        guard case .transient = result.rejected[0].reason else {
            return XCTFail("expected transient")
        }
    }

    // MARK: - rateLimited → backoff

    func testRateLimitedRespectsRetryAfter() async throws {
        let mock = MockCloudKitDatabase()
        await mock.queueSaveErrors([.rateLimited(retryAfter: 0.1)])
        let clock = RecordingClock()
        let transport = CloudKitGraphSyncTransport(
            backendID: SyncBackendID("dev"),
            database: mock,
            configuration: .init(clock: clock)
        )
        let result = try await transport.push(makeBatch([makeChange()]))
        XCTAssertEqual(result.accepted.count, 1)
        let sleeps = await clock.snapshot()
        XCTAssertEqual(sleeps, [0.1])
    }

    func testThreeConsecutiveThrottlesCapAt5Minutes() async throws {
        let mock = MockCloudKitDatabase()
        // No retryAfter hint — exponential backoff. With initial=120s, 3 consecutive throttles:
        //  attempt 0 → 120s, attempt 1 → 240s, attempt 2 → capped at 300s.
        await mock.queueSaveErrors([
            .serviceUnavailable(retryAfter: nil),
            .serviceUnavailable(retryAfter: nil),
            .serviceUnavailable(retryAfter: nil),
        ])
        let clock = RecordingClock()
        let transport = CloudKitGraphSyncTransport(
            backendID: SyncBackendID("dev"),
            database: mock,
            configuration: .init(initialBackoff: 120.0, maxBackoff: 300.0, maxBackoffAttempts: 6, clock: clock)
        )
        let result = try await transport.push(makeBatch([makeChange()]))
        XCTAssertEqual(result.accepted.count, 1)
        let sleeps = await clock.snapshot()
        XCTAssertEqual(sleeps.count, 3)
        XCTAssertLessThanOrEqual(sleeps.max() ?? 0, 300.0)
    }

    // MARK: - Backoff exhaustion surfaces transient

    func testBackoffExhaustionSurfacesTransientRejection() async throws {
        let mock = MockCloudKitDatabase()
        await mock.queueSaveErrors(Array(repeating: .rateLimited(retryAfter: 0), count: 5))
        let clock = RecordingClock()
        let transport = CloudKitGraphSyncTransport(
            backendID: SyncBackendID("dev"),
            database: mock,
            configuration: .init(initialBackoff: 0, maxBackoff: 0, maxBackoffAttempts: 3, clock: clock)
        )
        let change = makeChange()
        let result = try await transport.push(makeBatch([change]))
        XCTAssertTrue(result.accepted.isEmpty)
        XCTAssertEqual(result.rejected.count, 1)
        guard case .transient = result.rejected[0].reason else {
            return XCTFail("expected transient after backoff exhaustion")
        }
    }

    // MARK: - Order preservation

    func testAcceptedOrderFollowsInputOrderAcrossChunks() async throws {
        let mock = MockCloudKitDatabase()
        let transport = CloudKitGraphSyncTransport(
            backendID: SyncBackendID("dev"),
            database: mock,
            configuration: .init(maxBatchSize: 2, clock: RecordingClock())
        )
        let changes = (1...5).map { makeChange(sequence: Int64($0)) }
        let result = try await transport.push(makeBatch(changes))
        XCTAssertEqual(result.accepted, changes.map(\.id))
    }
}
