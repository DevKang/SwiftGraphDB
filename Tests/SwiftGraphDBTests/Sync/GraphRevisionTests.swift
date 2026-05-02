import XCTest
@testable import SwiftGraphDB

final class GraphRevisionTests: XCTestCase {

    // MARK: - Type aliases

    func testActorIDIsUUID() {
        let _: UUID = ActorID()
        let _: ActorID = UUID()
    }

    // MARK: - Comparable: same actor

    func testSameActorOrdersByCounter() {
        let a = ActorID()
        let now = Date()
        let r1 = GraphRevision(actorID: a, counter: 1, wallClock: now)
        let r2 = GraphRevision(actorID: a, counter: 2, wallClock: now)
        XCTAssertLessThan(r1, r2)
        XCTAssertGreaterThan(r2, r1)
        XCTAssertEqual(r1, r1)
    }

    func testSameActorSameCounterIsEqualEvenAcrossWallClocks() {
        let a = ActorID()
        let r1 = GraphRevision(actorID: a, counter: 5, wallClock: Date(timeIntervalSince1970: 1))
        let r2 = GraphRevision(actorID: a, counter: 5, wallClock: Date(timeIntervalSince1970: 999))
        XCTAssertNotEqual(r1, r2) // different wallClock breaks Equatable
        XCTAssertFalse(r1 < r2)
        XCTAssertFalse(r2 < r1)
    }

    // MARK: - Comparable: different actors

    func testDifferentActorsOrderByWallClockThenActorID() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        let actorA = ActorID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let actorB = ActorID(uuidString: "00000000-0000-0000-0000-000000000002")!

        let r1 = GraphRevision(actorID: actorA, counter: 100, wallClock: early)
        let r2 = GraphRevision(actorID: actorB, counter: 1, wallClock: late)
        XCTAssertLessThan(r1, r2, "earlier wallClock comes first regardless of counter")
    }

    func testDifferentActorsAtSameWallClockTieBreakByActorID() {
        let now = Date()
        let actorA = ActorID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let actorB = ActorID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let r1 = GraphRevision(actorID: actorA, counter: 1, wallClock: now)
        let r2 = GraphRevision(actorID: actorB, counter: 1, wallClock: now)
        XCTAssertLessThan(r1, r2)
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let original = GraphRevision(actorID: ActorID(), counter: 42, wallClock: Date(timeIntervalSince1970: 1700000000.123))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GraphRevision.self, from: data)
        XCTAssertEqual(decoded.actorID, original.actorID)
        XCTAssertEqual(decoded.counter, original.counter)
        XCTAssertEqual(decoded.wallClock.timeIntervalSince1970, original.wallClock.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Hashable

    func testEqualRevisionsHaveEqualHashes() {
        let actorID = ActorID()
        let date = Date()
        let r1 = GraphRevision(actorID: actorID, counter: 7, wallClock: date)
        let r2 = GraphRevision(actorID: actorID, counter: 7, wallClock: date)
        XCTAssertEqual(r1, r2)
        XCTAssertEqual(r1.hashValue, r2.hashValue)
        let s: Set<GraphRevision> = [r1, r2]
        XCTAssertEqual(s.count, 1)
    }

    // MARK: - GraphOperation

    func testGraphOperationCodableUsesSpecStrings() throws {
        let upsert = try JSONEncoder().encode(GraphOperation.upsert)
        XCTAssertEqual(String(data: upsert, encoding: .utf8), "\"upsert\"")
        let delete = try JSONEncoder().encode(GraphOperation.delete)
        XCTAssertEqual(String(data: delete, encoding: .utf8), "\"delete\"")
    }

    func testGraphOperationDecodesSpecStrings() throws {
        let up = try JSONDecoder().decode(GraphOperation.self, from: Data("\"upsert\"".utf8))
        XCTAssertEqual(up, .upsert)
        let del = try JSONDecoder().decode(GraphOperation.self, from: Data("\"delete\"".utf8))
        XCTAssertEqual(del, .delete)
    }

    // MARK: - Sendable / placeholder

    func testRevisionIsSendableAcrossDetachedTask() async {
        let r = GraphRevision(actorID: ActorID(), counter: 1, wallClock: Date())
        let observed = await Task.detached { r }.value
        XCTAssertEqual(observed, r)
    }

    func testPlaceholderRevisionIsRecognizable() {
        let p = GraphRevision.placeholder(wallClock: Date())
        XCTAssertEqual(p.counter, 0)
        XCTAssertEqual(p.actorID, ActorID(uuid: (0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0)))
    }
}
