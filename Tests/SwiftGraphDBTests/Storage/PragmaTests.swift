import XCTest
@testable import SwiftGraphDB

final class PragmaTests: XCTestCase {

    func testWALPragmaAppliedOnFileStore() throws {
        let url = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = try SQLiteStore(at: url, configuration: .default)
        defer { store.close() }

        let mode = try pragmaText(store, "journal_mode")
        XCTAssertEqual(mode?.lowercased(), "wal")
    }

    func testSynchronousNormalByDefault() throws {
        let url = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = try SQLiteStore(at: url, configuration: .default)
        defer { store.close() }

        let value = try pragmaInt(store, "synchronous")
        XCTAssertEqual(value, 1) // 1 = NORMAL
    }

    func testMmapSizeApplied() throws {
        let url = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = try SQLiteStore(at: url, configuration: .default)
        defer { store.close() }

        let mmap = try pragmaInt(store, "mmap_size")
        XCTAssertEqual(mmap, 134_217_728)
    }

    func testCustomConfigurationOverridesSynchronous() throws {
        let url = try tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var custom = SQLiteConfiguration.default
        custom.synchronous = .full

        let store = try SQLiteStore(at: url, configuration: custom)
        defer { store.close() }

        let value = try pragmaInt(store, "synchronous")
        XCTAssertEqual(value, 2) // 2 = FULL
    }

    func testInMemoryStoreFallsBackGracefullyWithoutWAL() throws {
        // WAL is unsupported on `:memory:`. Open should still succeed; journal_mode falls back.
        let store = try SQLiteStore.openInMemory(configuration: .default)
        defer { store.close() }

        let mode = try pragmaText(store, "journal_mode")
        XCTAssertNotNil(mode)
        XCTAssertNotEqual(mode?.lowercased(), "wal", "WAL is not supported for :memory:")
    }

    // MARK: - Helpers

    private func pragmaText(_ store: SQLiteStore, _ name: String) throws -> String? {
        try store.query("PRAGMA \(name)") { $0.text(at: 0) }.first.flatMap { $0 }
    }

    private func pragmaInt(_ store: SQLiteStore, _ name: String) throws -> Int64? {
        try store.query("PRAGMA \(name)") { $0.int(at: 0) }.first.flatMap { $0 }
    }

    private func tempStoreURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftGraphDB-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.sqlite")
    }
}
