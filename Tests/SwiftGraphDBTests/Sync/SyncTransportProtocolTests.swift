import XCTest
@testable import SwiftGraphDB

final class SyncTransportProtocolTests: XCTestCase {

    /// Tiny conforming stub used to verify the protocol shape. No external SDK references.
    struct StubTransport: GraphSyncTransport {
        let backendID: SyncBackendID = "stub"
        func push(_ batch: ChangeBatch) async throws -> PushResult {
            PushResult(accepted: batch.changes.map(\.id), rejected: [], checkpoint: nil)
        }
        func pull(since checkpoint: SyncCheckpoint?) async throws -> PullResult {
            PullResult(changes: [], checkpoint: SyncCheckpoint(backendID: backendID, data: Data()), hasMore: false)
        }
    }

    func testProtocolStubCompilesWithoutBackendDependency() async throws {
        let transport = StubTransport()
        let batch = ChangeBatch(graphID: UUID(), backendID: "stub", changes: [], highWatermark: 0)
        let push = try await transport.push(batch)
        XCTAssertTrue(push.rejected.isEmpty)
        let pull = try await transport.pull(since: nil)
        XCTAssertFalse(pull.hasMore)
    }

    func testRejectionReasonCodableRoundTripsEveryCase() throws {
        let cases: [SyncRejectionReason] = [
            .conflict(
                remote: GraphRecordPayload(properties: ["x": .int(1)]),
                base: nil
            ),
            .conflict(
                remote: GraphRecordPayload(properties: ["x": .int(1)]),
                base: GraphRecordPayload(properties: [:])
            ),
            .validationFailed("bad"),
            .transient("network"),
            .permanent("auth")
        ]
        for c in cases {
            let data = try JSONEncoder().encode(c)
            let decoded = try JSONDecoder().decode(SyncRejectionReason.self, from: data)
            XCTAssertEqual(c, decoded)
        }
    }

    func testPushResultMixedAcceptedRejected() {
        let id1 = UUID(); let id2 = UUID()
        let result = PushResult(
            accepted: [id1],
            rejected: [SyncRejection(changeID: id2, reason: .transient("retry"))],
            checkpoint: SyncCheckpoint(backendID: "stub", data: Data([0x01]))
        )
        XCTAssertEqual(result.accepted, [id1])
        XCTAssertEqual(result.rejected.count, 1)
        if case .transient = result.rejected[0].reason {} else {
            XCTFail("expected .transient, got \(result.rejected[0].reason)")
        }
        XCTAssertNotNil(result.checkpoint)
    }
}
