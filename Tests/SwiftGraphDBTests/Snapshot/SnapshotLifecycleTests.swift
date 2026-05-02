import XCTest
@testable import SwiftGraphDB

final class SnapshotLifecycleTests: XCTestCase {

    private func tempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftGraphDB-snapshot-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("graph.snapshot")
    }

    private func samplePayload(schemaVersion: Int32 = 2) -> SnapshotPayload {
        SnapshotPayload(
            schemaVersion: schemaVersion,
            nodeIDs: [],
            labels: [:],
            forwardEdges: [],
            reverseEdges: []
        )
    }

    func testLoadReturnsValidPayloadAndEmitsLoaded() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try! SnapshotWriter.write(samplePayload(), to: url)

        let lifecycle = SnapshotLifecycle(url: url)
        let payload = lifecycle.tryLoad(expectedSchemaVersion: 2)
        XCTAssertNotNil(payload)

        var iter = lifecycle.events.makeAsyncIterator()
        let first = await iter.next()
        XCTAssertEqual(first, .loaded)
    }

    func testCorruptedSnapshotIsDeletedAndEventsEmitted() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try SnapshotWriter.write(samplePayload(), to: url)

        // Corrupt the file.
        var data = try Data(contentsOf: url)
        data[40] ^= 0xFF
        try data.write(to: url)

        let lifecycle = SnapshotLifecycle(url: url)
        let payload = lifecycle.tryLoad(expectedSchemaVersion: 2)
        XCTAssertNil(payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "corrupt snapshot must be deleted")

        var iter = lifecycle.events.makeAsyncIterator()
        let first = await iter.next()
        XCTAssertNotNil(first)
        if case .discardedCorrupt = first {
            // ok
        } else {
            XCTFail("expected .discardedCorrupt, got \(String(describing: first))")
        }
        let second = await iter.next()
        XCTAssertEqual(second, .rebuilt)
    }

    func testSchemaMismatchDiscardsAndRebuilds() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try SnapshotWriter.write(samplePayload(schemaVersion: 1), to: url)

        let lifecycle = SnapshotLifecycle(url: url)
        let payload = lifecycle.tryLoad(expectedSchemaVersion: 2)
        XCTAssertNil(payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDisabledPolicyEmitsSkippedAndIgnoresFile() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try SnapshotWriter.write(samplePayload(), to: url)

        let lifecycle = SnapshotLifecycle(url: url, policy: .disabled)
        let payload = lifecycle.tryLoad(expectedSchemaVersion: 2)
        XCTAssertNil(payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      ".disabled must not delete the file")

        var iter = lifecycle.events.makeAsyncIterator()
        let first = await iter.next()
        XCTAssertEqual(first, .skipped)
    }

    func testWriteEmitsWrittenEvent() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let lifecycle = SnapshotLifecycle(url: url)
        try lifecycle.write(samplePayload())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        var iter = lifecycle.events.makeAsyncIterator()
        let first = await iter.next()
        XCTAssertEqual(first, .written)
    }
}
