import XCTest
@testable import SwiftGraphDB

final class SnapshotReadTests: XCTestCase {

    private func tempSnapshotURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftGraphDB-snapshot-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("graph.snapshot")
    }

    private func samplePayload(schemaVersion: Int32 = 2) -> SnapshotPayload {
        let a = NodeID()
        let b = NodeID()
        return SnapshotPayload(
            schemaVersion: schemaVersion,
            nodeIDs: [a, b],
            labels: ["P": [a, b]],
            forwardEdges: [],
            reverseEdges: []
        )
    }

    func testValidSnapshotRoundTripsThroughDisk() throws {
        let url = tempSnapshotURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try SnapshotWriter.write(samplePayload(), to: url)
        let payload = try SnapshotReader.read(at: url, expectedSchemaVersion: 2)
        XCTAssertEqual(payload.nodeIDs.count, 2)
    }

    func testCorruptedFileSurfacesChecksumMismatch() throws {
        let url = tempSnapshotURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try SnapshotWriter.write(samplePayload(), to: url)
        // Flip a body byte.
        var data = try Data(contentsOf: url)
        data[40] ^= 0xFF
        try data.write(to: url)
        XCTAssertThrowsError(try SnapshotReader.read(at: url, expectedSchemaVersion: 2)) { error in
            guard case SnapshotError.checksumMismatch = error else {
                return XCTFail("expected .checksumMismatch, got \(error)")
            }
        }
    }

    func testSchemaVersionMismatchSurfaces() throws {
        let url = tempSnapshotURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try SnapshotWriter.write(samplePayload(schemaVersion: 1), to: url)
        XCTAssertThrowsError(try SnapshotReader.read(at: url, expectedSchemaVersion: 2)) { error in
            guard case SnapshotError.schemaVersionMismatch = error else {
                return XCTFail("expected .schemaVersionMismatch, got \(error)")
            }
        }
    }

    func testTruncatedFileSurfacesMalformed() throws {
        let url = tempSnapshotURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try SnapshotWriter.write(samplePayload(), to: url)
        let trimmed = try Data(contentsOf: url).prefix(20)
        try trimmed.write(to: url)
        XCTAssertThrowsError(try SnapshotReader.read(at: url, expectedSchemaVersion: 2)) { error in
            guard case SnapshotError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    func testReadOfMissingFileThrowsCocoaError() {
        let url = tempSnapshotURL().appendingPathComponent("missing.snapshot")
        XCTAssertThrowsError(try SnapshotReader.read(at: url, expectedSchemaVersion: 2))
    }
}
