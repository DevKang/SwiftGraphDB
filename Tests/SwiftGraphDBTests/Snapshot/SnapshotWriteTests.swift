import XCTest
@testable import SwiftGraphDB

final class SnapshotWriteTests: XCTestCase {

    private func samplePayload() -> SnapshotPayload {
        let a = NodeID()
        let b = NodeID()
        let edge = EdgeID()
        return SnapshotPayload(
            schemaVersion: 2,
            nodeIDs: [a, b],
            labels: ["Person": [a, b]],
            forwardEdges: [.init(from: a, to: b, edgeID: edge, type: "KNOWS")],
            reverseEdges: [.init(from: a, to: b, edgeID: edge, type: "KNOWS")]
        )
    }

    func testEncodeDecodeRoundTrip() throws {
        let payload = samplePayload()
        let encoded = try SnapshotFormat.encode(payload)
        let decoded = try SnapshotFormat.decode(encoded)
        XCTAssertEqual(decoded.nodeIDs.count, 2)
        XCTAssertEqual(decoded.forwardEdges.count, 1)
    }

    func testMagicMismatchThrowsMalformed() {
        var data = try! SnapshotFormat.encode(samplePayload())
        data[0] = 0xFF // corrupt magic
        XCTAssertThrowsError(try SnapshotFormat.decode(data)) { error in
            guard case SnapshotError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    func testFormatVersionMismatchThrows() {
        var data = try! SnapshotFormat.encode(samplePayload())
        // Format version sits at byte 8..<12.
        data[8] = 99
        data[9] = 0; data[10] = 0; data[11] = 0
        XCTAssertThrowsError(try SnapshotFormat.decode(data)) { error in
            guard case SnapshotError.formatVersionMismatch = error else {
                return XCTFail("expected .formatVersionMismatch, got \(error)")
            }
        }
    }

    func testCorruptedCRCThrows() throws {
        var data = try SnapshotFormat.encode(samplePayload())
        data[40] ^= 0xFF // corrupt body byte
        XCTAssertThrowsError(try SnapshotFormat.decode(data)) { error in
            guard case SnapshotError.checksumMismatch = error else {
                return XCTFail("expected .checksumMismatch, got \(error)")
            }
        }
    }

    func testWriterAtomicallyReplacesExisting() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftGraphDB-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("graph.snapshot")
        try SnapshotWriter.write(samplePayload(), to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Overwrite with a different payload.
        var p2 = samplePayload()
        let extra = NodeID()
        p2 = SnapshotPayload(
            schemaVersion: p2.schemaVersion,
            nodeIDs: p2.nodeIDs + [extra],
            labels: p2.labels,
            forwardEdges: p2.forwardEdges,
            reverseEdges: p2.reverseEdges
        )
        try SnapshotWriter.write(p2, to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path),
                       "tmp file must be cleaned up after successful rename")

        let data = try Data(contentsOf: url)
        let decoded = try SnapshotFormat.decode(data)
        XCTAssertEqual(decoded.nodeIDs.count, 3)
    }

    func testBuilderFromInMemoryStateRoundTrips() {
        var indexMap = IndexMap()
        var labelIndex = LabelIndex()
        let a = NodeID(); _ = indexMap.intern(a); labelIndex.add(a, label: "P")
        let b = NodeID(); _ = indexMap.intern(b); labelIndex.add(b, label: "P")
        let edge = EdgeRecord(toID: b, edgeID: EdgeID(), type: "L")
        let forward = CSRAdjacency(nodeCount: 2, edges: [(0, edge)])
        let reverse = CSRAdjacency(nodeCount: 2, edges: [(1, EdgeRecord(toID: a, edgeID: edge.edgeID, type: "L"))])

        let payload = SnapshotBuilder.build(
            schemaVersion: 2, indexMap: indexMap, labelIndex: labelIndex,
            forward: forward, reverse: reverse
        )
        let materialised = SnapshotBuilder.materialise(payload)

        XCTAssertEqual(materialised.indexMap.count, 2)
        XCTAssertEqual(materialised.forward.degree(of: 0), 1)
        XCTAssertEqual(materialised.reverse.degree(of: 1), 1)
        XCTAssertEqual(materialised.labelIndex.nodes(labeled: "P").count, 2)
    }
}
