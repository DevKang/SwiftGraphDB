import Foundation

/// Reusable contract assertions parametrised over a `GraphSyncTransport`. Adapter authors
/// instantiate this with their concrete transport (or a mock) and call each test method;
/// every assertion exercises a SPEC §16.3 line item.
///
/// Returns Bool/throws so the caller (XCTest, swift-testing, etc.) can decide failure
/// surfacing — keeps the contract suite framework-agnostic.
public struct GraphSyncContract<Transport: GraphSyncTransport> {

    public let make: @Sendable () async -> (transport: Transport, reset: @Sendable () async -> Void)

    public init(make: @escaping @Sendable () async -> (transport: Transport, reset: @Sendable () async -> Void)) {
        self.make = make
    }

    /// Assertion failure type that carries enough context for both XCTest and direct logging.
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Round-trip a single change through push then pull (different device).
    public func runRoundTrip(actorIDA: ActorID, actorIDB: ActorID) async throws {
        let (transportA, resetA) = await make()
        let (transportB, _) = await make()
        defer { Task { await resetA() } }

        let change = sampleChange(actorID: actorIDA, sequence: 1)
        let push = try await transportA.push(.init(graphID: change.graphID, backendID: transportA.backendID, changes: [change], highWatermark: 0))
        guard push.rejected.isEmpty else {
            throw Failure(description: "expected accept, got rejections: \(push.rejected)")
        }
        let pull = try await transportB.pull(since: nil)
        guard pull.changes.contains(where: { $0.id == change.id }) else {
            throw Failure(description: "device B did not observe pushed change")
        }
    }

    /// Re-pushing an already-accepted change leaves the backend in the same state.
    public func runIdempotentRePush(actorID: ActorID) async throws {
        let (transport, _) = await make()
        let change = sampleChange(actorID: actorID, sequence: 1)
        let batch = ChangeBatch(graphID: change.graphID, backendID: transport.backendID, changes: [change], highWatermark: 0)
        _ = try await transport.push(batch)
        let second = try await transport.push(batch)
        // Either accepted again (idempotent) or surfaced as a conflict/permanent rejection.
        let acceptedAgain = second.accepted.contains(change.id)
        let rejectedDuplicate = second.rejected.contains(where: { $0.changeID == change.id })
        guard acceptedAgain || rejectedDuplicate else {
            throw Failure(description: "second push neither accepted nor rejected the duplicate: \(second)")
        }
    }

    public func runCheckpointResume(actorIDA: ActorID, actorIDB: ActorID) async throws {
        let (transportA, _) = await make()
        let (transportB, _) = await make()
        let first = sampleChange(actorID: actorIDA, sequence: 1)
        let second = sampleChange(actorID: actorIDA, sequence: 2)
        _ = try await transportA.push(.init(graphID: first.graphID, backendID: transportA.backendID, changes: [first], highWatermark: 0))
        let pullOne = try await transportB.pull(since: nil)
        guard pullOne.changes.contains(where: { $0.id == first.id }) else {
            throw Failure(description: "first pull missing change")
        }
        _ = try await transportA.push(.init(graphID: second.graphID, backendID: transportA.backendID, changes: [second], highWatermark: 0))
        let pullTwo = try await transportB.pull(since: pullOne.checkpoint)
        guard pullTwo.changes.map(\.id) == [second.id] else {
            throw Failure(description: "checkpoint resume returned \(pullTwo.changes.map(\.id))")
        }
    }

    private func sampleChange(actorID: ActorID, sequence: Int64) -> GraphChange {
        GraphChange(
            id: UUID(),
            graphID: UUID(),
            actorID: actorID,
            sequence: sequence,
            entity: GraphEntityRef(kind: .node, id: UUID()),
            operation: .upsert,
            payload: GraphRecordPayload(properties: ["s": .int(sequence)], label: "P"),
            baseRevision: nil,
            revision: GraphRevision(actorID: actorID, counter: sequence, wallClock: Date()),
            createdAt: Date()
        )
    }
}
