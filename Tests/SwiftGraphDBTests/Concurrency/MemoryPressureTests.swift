import XCTest
@testable import SwiftGraphDB

final class MemoryPressureTests: XCTestCase {

    func testWarningEventClearsPropertyCache() async throws {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        let actor = await GraphActor(store: store)
        let id = try await actor.addNode(label: "P", properties: ["x": .int(1)])
        _ = try await actor.cachedProperties(for: id)   // populate cache
        let prePressure = await actor.propertyCacheStats
        XCTAssertEqual(prePressure.hits, 0)
        XCTAssertEqual(prePressure.misses, 1)

        let monitor = TestMemoryPressureMonitor()
        await actor.attachMemoryPressureMonitor(monitor)
        monitor.fire(.warning)

        // Allow the Task scheduled by the handler to land.
        try await Task.sleep(nanoseconds: 50_000_000)

        let stats = await actor.propertyCacheStats
        XCTAssertEqual(stats.hits, 0)
        XCTAssertEqual(stats.misses, 0, "warning resets stats and drops cached entries")
    }

    func testCriticalEventClearsCacheAndEdgeLog() async throws {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        let actor = await GraphActor(store: store)
        let a = try await actor.addNode(label: "P", properties: [:])
        let b = try await actor.addNode(label: "P", properties: [:])
        _ = try await actor.addEdge(from: a, to: b, type: "L", properties: [:])

        // EdgeLog should have one entry at this point.
        let beforeSize = await actor.snapshotForTests().edgeLog.size
        XCTAssertEqual(beforeSize, 1)

        let monitor = TestMemoryPressureMonitor()
        await actor.attachMemoryPressureMonitor(monitor)
        monitor.fire(.critical)

        try await Task.sleep(nanoseconds: 50_000_000)
        let afterSize = await actor.snapshotForTests().edgeLog.size
        XCTAssertEqual(afterSize, 0)
    }

    func testCancelStopsHandlerInvocations() async throws {
        let store = try SQLiteStore.openInMemory()
        try MigrationRunner.runDefault(on: store)
        let actor = await GraphActor(store: store)

        let monitor = TestMemoryPressureMonitor()
        await actor.attachMemoryPressureMonitor(monitor)
        monitor.cancel()
        monitor.fire(.warning) // ignored — handler was nil'd

        try await Task.sleep(nanoseconds: 30_000_000)
        let stats = await actor.propertyCacheStats
        XCTAssertEqual(stats.hits, 0)
        XCTAssertEqual(stats.misses, 0)
    }
}
