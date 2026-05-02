import XCTest
@testable import SwiftGraphDB

final class ConflictResolverTests: XCTestCase {

    private func conflict(
        base: [String: PropertyValue]?,
        local: [String: PropertyValue]?,
        remote: [String: PropertyValue]
    ) -> GraphConflict {
        GraphConflict(
            backendID: "test",
            entity: GraphEntityRef(kind: .node, id: UUID()),
            base: base.map { GraphRecordPayload(properties: $0) },
            local: local.map { GraphRecordPayload(properties: $0) },
            remote: GraphRecordPayload(properties: remote)
        )
    }

    func testOnlyClientChangedFieldKeepsLocal() async throws {
        let result = try await FieldLevelMergeResolver().resolve(conflict(
            base: ["name": "Alice", "age": .int(30)],
            local: ["name": "Alice2", "age": .int(30)],
            remote: ["name": "Alice", "age": .int(30)]
        ))
        guard case .merge(let payload) = result else {
            return XCTFail("expected .merge, got \(result)")
        }
        XCTAssertEqual(payload.properties["name"], "Alice2")
        XCTAssertEqual(payload.properties["age"], .int(30))
    }

    func testOnlyServerChangedKeepsRemote() async throws {
        let result = try await FieldLevelMergeResolver().resolve(conflict(
            base: ["name": "Alice", "age": .int(30)],
            local: ["name": "Alice", "age": .int(30)],
            remote: ["name": "Alice", "age": .int(31)]
        ))
        guard case .merge(let payload) = result else { return XCTFail() }
        XCTAssertEqual(payload.properties["age"], .int(31))
    }

    func testBothChangedSameFieldRemoteWinsByDefault() async throws {
        let result = try await FieldLevelMergeResolver().resolve(conflict(
            base: ["name": "Alice"],
            local: ["name": "Local"],
            remote: ["name": "Remote"]
        ))
        guard case .merge(let payload) = result else { return XCTFail() }
        XCTAssertEqual(payload.properties["name"], "Remote")
    }

    func testBothChangedSameValueIsNotAConflict() async throws {
        let result = try await FieldLevelMergeResolver(sameFieldConflict: .fail).resolve(conflict(
            base: ["name": "Alice"],
            local: ["name": "Bob"],
            remote: ["name": "Bob"]
        ))
        guard case .merge(let payload) = result else { return XCTFail() }
        XCTAssertEqual(payload.properties["name"], "Bob")
    }

    func testDeleteVsUpdateFailsByDefault() async throws {
        let result = try await FieldLevelMergeResolver().resolve(conflict(
            base: ["name": "Alice"],
            local: nil,                                 // locally deleted
            remote: ["name": "Alice2"]
        ))
        guard case .fail = result else { return XCTFail("expected .fail, got \(result)") }
    }

    func testDeleteVsUpdateRemoteWinsPolicy() async throws {
        let resolver = FieldLevelMergeResolver(deleteConflict: .remoteWins)
        let result = try await resolver.resolve(conflict(
            base: ["name": "Alice"],
            local: nil,
            remote: ["name": "Alice2"]
        ))
        guard case .useRemote = result else { return XCTFail() }
    }

    func testDeleteVsUpdateDeleteWinsPolicy() async throws {
        let resolver = FieldLevelMergeResolver(deleteConflict: .deleteWins)
        let result = try await resolver.resolve(conflict(
            base: ["name": "Alice"],
            local: nil,
            remote: ["name": "Alice2"]
        ))
        guard case .delete = result else { return XCTFail() }
    }

    func testRemoteWinsResolverShortCircuits() async throws {
        let result = try await RemoteWinsResolver().resolve(conflict(
            base: ["name": "Alice"],
            local: ["name": "Local"],
            remote: ["name": "Remote"]
        ))
        guard case .useRemote = result else { return XCTFail() }
    }

    func testLocalWinsResolverShortCircuits() async throws {
        let result = try await LocalWinsResolver().resolve(conflict(
            base: ["name": "Alice"],
            local: ["name": "Local"],
            remote: ["name": "Remote"]
        ))
        guard case .useLocal = result else { return XCTFail() }
    }

    func testDeterminismFuzz() async throws {
        // Same input → same output across two runs.
        let resolver = FieldLevelMergeResolver()
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let baseV = Int(rng.next() % 10)
            let localV = Int(rng.next() % 10)
            let remoteV = Int(rng.next() % 10)
            let conflict = conflict(
                base: ["x": .int(Int64(baseV))],
                local: ["x": .int(Int64(localV))],
                remote: ["x": .int(Int64(remoteV))]
            )
            let r1 = try await resolver.resolve(conflict)
            let r2 = try await resolver.resolve(conflict)
            switch (r1, r2) {
            case (.merge(let a), .merge(let b)):
                XCTAssertEqual(a.properties["x"], b.properties["x"])
            case (.fail, .fail), (.useLocal, .useLocal), (.useRemote, .useRemote), (.delete, .delete):
                break
            default:
                XCTFail("non-deterministic: \(r1) vs \(r2)")
            }
        }
    }
}
