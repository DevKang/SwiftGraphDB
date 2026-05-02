import XCTest
@testable import SwiftGraphDB
@testable import SwiftGraphDBCloudKit

final class CloudKitAccountStateTests: XCTestCase {

    /// Mutable account-state probe for tests. Production wraps `CKContainer`.
    actor MockAccountStatusProbe: CloudKitAccountStatusProbe {
        private var status: CloudKitAccountStatus
        private var nextError: (any Error)?

        init(_ initial: CloudKitAccountStatus = .available) {
            self.status = initial
        }

        func set(_ status: CloudKitAccountStatus) { self.status = status }
        func setError(_ error: any Error) { self.nextError = error }

        nonisolated func currentStatus() async throws -> CloudKitAccountStatus {
            try await read()
        }

        private func read() throws -> CloudKitAccountStatus {
            if let err = nextError {
                nextError = nil
                throw err
            }
            return status
        }
    }

    private func makeChange() -> GraphChange {
        let actor = ActorID()
        return GraphChange(
            id: UUID(), graphID: UUID(), actorID: actor,
            sequence: 1,
            entity: GraphEntityRef(kind: .node, id: UUID()),
            operation: .upsert,
            payload: GraphRecordPayload(properties: ["x": .int(1)], label: "P"),
            baseRevision: nil,
            revision: GraphRevision(actorID: actor, counter: 1, wallClock: Date()),
            createdAt: Date()
        )
    }

    private func makeBatch(_ changes: [GraphChange]) -> ChangeBatch {
        ChangeBatch(graphID: UUID(), backendID: SyncBackendID("dev"), changes: changes, highWatermark: 0)
    }

    func testNoAccountThrowsNotAvailableOnPush() async throws {
        let probe = MockAccountStatusProbe(.noAccount)
        let mock = MockCloudKitDatabase()
        let transport = CloudKitGraphSyncTransport(
            backendID: SyncBackendID("dev"),
            database: mock,
            configuration: .init(accountProbe: probe)
        )
        do {
            _ = try await transport.push(makeBatch([makeChange()]))
            XCTFail("expected throw")
        } catch CloudKitAccountError.notAvailable(let s) {
            XCTAssertEqual(s, .noAccount)
        }
        // The mock database was never touched — preflight ran first.
        let calls = await mock.saveCallCount
        XCTAssertEqual(calls, 0)
    }

    func testNoAccountThrowsOnPull() async throws {
        let probe = MockAccountStatusProbe(.noAccount)
        let mock = MockCloudKitDatabase()
        let transport = CloudKitGraphSyncTransport(
            backendID: SyncBackendID("dev"),
            database: mock,
            configuration: .init(accountProbe: probe)
        )
        do {
            _ = try await transport.pull(since: nil)
            XCTFail("expected throw")
        } catch CloudKitAccountError.notAvailable {
            // ok
        }
    }

    func testTransitionToAvailableLetsPushSucceed() async throws {
        let probe = MockAccountStatusProbe(.noAccount)
        let mock = MockCloudKitDatabase()
        let transport = CloudKitGraphSyncTransport(
            backendID: SyncBackendID("dev"),
            database: mock,
            configuration: .init(accountProbe: probe)
        )
        // First attempt fails because no account.
        do {
            _ = try await transport.push(makeBatch([makeChange()]))
            XCTFail("expected throw")
        } catch CloudKitAccountError.notAvailable {}

        // User signs in.
        await probe.set(.available)

        // Next push goes through.
        let change = makeChange()
        let result = try await transport.push(makeBatch([change]))
        XCTAssertEqual(result.accepted, [change.id])
    }

    func testEntitlementMisconfigSurfacesAsConfigurationError() async throws {
        let probe = MockAccountStatusProbe()
        await probe.setError(CloudKitConfigurationError.missingEntitlement("com.apple.developer.icloud-services"))
        let mock = MockCloudKitDatabase()
        let transport = CloudKitGraphSyncTransport(
            backendID: SyncBackendID("dev"),
            database: mock,
            configuration: .init(accountProbe: probe)
        )
        do {
            _ = try await transport.push(makeBatch([makeChange()]))
            XCTFail("expected throw")
        } catch let err as CloudKitConfigurationError {
            guard case .missingEntitlement = err else {
                return XCTFail("expected missingEntitlement, got \(err)")
            }
        }
    }

    func testPreflightDisabledSkipsAccountCheck() async throws {
        let probe = MockAccountStatusProbe(.noAccount)
        let mock = MockCloudKitDatabase()
        let transport = CloudKitGraphSyncTransport(
            backendID: SyncBackendID("dev"),
            database: mock,
            configuration: .init(preflightAccountState: false, accountProbe: probe)
        )
        // Even with .noAccount, the transport pushes and lets the database respond.
        let change = makeChange()
        let result = try await transport.push(makeBatch([change]))
        XCTAssertEqual(result.accepted, [change.id])
        let calls = await mock.saveCallCount
        XCTAssertEqual(calls, 1)
    }

    func testNoProbeSkipsPreflight() async throws {
        let mock = MockCloudKitDatabase()
        let transport = CloudKitGraphSyncTransport(
            backendID: SyncBackendID("dev"),
            database: mock,
            configuration: .init(accountProbe: nil)
        )
        let change = makeChange()
        let result = try await transport.push(makeBatch([change]))
        XCTAssertEqual(result.accepted, [change.id])
    }
}
