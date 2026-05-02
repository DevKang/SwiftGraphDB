import Foundation

/// Magic prefix for `graph.snapshot` files. Exactly 8 bytes so we can read+verify in one call.
public let snapshotMagic: [UInt8] = [0x53, 0x47, 0x44, 0x42, 0x53, 0x4E, 0x50, 0x31] // "SGDBSNP1"

/// Snapshot file layout (SPEC §6.4 / §15.2 — Option C, custom packed format):
///
/// ```
/// magic               8 bytes  "SGDBSNP1"
/// formatVersion       4 bytes  Int32 LE  — file format version
/// schemaVersion       4 bytes  Int32 LE  — db_meta.schema_version at write time
/// payloadLength       8 bytes  Int64 LE  — bytes that follow before the CRC
/// payload             N bytes  JSON-encoded SnapshotPayload
/// crc32               4 bytes  UInt32 LE — CRC32 of the payload
/// ```
///
/// JSON keeps the writer simple while remaining versionable. Future iterations can swap to
/// FlatBuffers or a packed binary layout behind the same file framing.
public struct SnapshotPayload: Codable, Sendable, Equatable {
    public struct EdgeRow: Codable, Sendable, Equatable {
        public let from: NodeID
        public let to: NodeID
        public let edgeID: EdgeID
        public let type: String
    }

    public let formatVersion: Int32 = SnapshotFormat.currentFormatVersion
    public let schemaVersion: Int32
    public let nodeIDs: [NodeID]
    public let labels: [String: [NodeID]]
    public let forwardEdges: [EdgeRow]
    public let reverseEdges: [EdgeRow]
}

/// Constants and helpers for the on-disk launch-snapshot binary format.
public enum SnapshotFormat {
    public static let currentFormatVersion: Int32 = 1

    /// Encodes a `SnapshotPayload` into the SPEC §6.4 file layout (magic + header + payload + CRC32).
    public static func encode(_ payload: SnapshotPayload) throws -> Data {
        var out = Data()
        out.append(contentsOf: snapshotMagic)
        appendLE(&out, value: payload.formatVersion)
        appendLE(&out, value: payload.schemaVersion)

        let body = try JSONEncoder().encode(payload)
        appendLE(&out, value: Int64(body.count))
        out.append(body)

        let crc = crc32(body)
        appendLE(&out, value: crc)
        return out
    }

    /// Decode the file framing and the payload. Verifies (in order) magic, format version,
    /// length, CRC32, and finally the payload JSON. Each layer surfaces a typed error.
    public static func decode(_ data: Data) throws -> SnapshotPayload {
        guard data.count >= snapshotMagic.count + 16 + 4 else {
            throw SnapshotError.malformed("file too short for header")
        }
        guard Array(data.prefix(snapshotMagic.count)) == snapshotMagic else {
            throw SnapshotError.malformed("bad magic")
        }
        let cursor = snapshotMagic.count
        let format = readLEInt32(data, at: cursor)
        let schema = readLEInt32(data, at: cursor + 4)
        let length = readLEInt64(data, at: cursor + 8)
        guard format == currentFormatVersion else {
            throw SnapshotError.formatVersionMismatch(found: format, expected: currentFormatVersion)
        }
        let payloadStart = cursor + 16
        guard data.count == payloadStart + Int(length) + 4 else {
            throw SnapshotError.malformed("payload length \(length) doesn't match file size")
        }
        let body = data.subdata(in: payloadStart..<payloadStart + Int(length))
        let storedCRC = readLEUInt32(data, at: payloadStart + Int(length))
        let computedCRC = crc32(body)
        guard storedCRC == computedCRC else {
            throw SnapshotError.checksumMismatch
        }

        var decoded = try JSONDecoder().decode(SnapshotPayload.self, from: body)
        if decoded.schemaVersion != schema {
            decoded = SnapshotPayload(
                schemaVersion: schema,
                nodeIDs: decoded.nodeIDs,
                labels: decoded.labels,
                forwardEdges: decoded.forwardEdges,
                reverseEdges: decoded.reverseEdges
            )
        }
        return decoded
    }

    // MARK: - Helpers

    static func appendLE(_ data: inout Data, value: Int32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    static func appendLE(_ data: inout Data, value: Int64) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    static func appendLE(_ data: inout Data, value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    static func readLEInt32(_ data: Data, at offset: Int) -> Int32 {
        var v: Int32 = 0
        withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst, from: offset..<offset + 4)
        }
        return Int32(littleEndian: v)
    }
    static func readLEInt64(_ data: Data, at offset: Int) -> Int64 {
        var v: Int64 = 0
        withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst, from: offset..<offset + 8)
        }
        return Int64(littleEndian: v)
    }
    static func readLEUInt32(_ data: Data, at offset: Int) -> UInt32 {
        var v: UInt32 = 0
        withUnsafeMutableBytes(of: &v) { dst in
            data.copyBytes(to: dst, from: offset..<offset + 4)
        }
        return UInt32(littleEndian: v)
    }

    /// CRC32 (IEEE polynomial). Local implementation so we don't depend on `zlib`.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask: UInt32 = (crc & 1) == 1 ? 0xEDB8_8320 : 0
                crc = (crc >> 1) ^ mask
            }
        }
        return ~crc
    }
}

/// Errors thrown while reading or writing a launch snapshot.
public enum SnapshotError: Error, Equatable {
    case malformed(String)
    case formatVersionMismatch(found: Int32, expected: Int32)
    case schemaVersionMismatch(found: Int32, expected: Int32)
    case checksumMismatch
    case writeFailed(String)
}

/// Build a `SnapshotPayload` from the live in-memory state plus a schema version.
public enum SnapshotBuilder {
    public static func build(
        schemaVersion: Int32,
        indexMap: IndexMap,
        labelIndex: LabelIndex,
        forward: CSRAdjacency,
        reverse: CSRAdjacency
    ) -> SnapshotPayload {
        // Forward / reverse CSR → flat list. We materialise the source NodeID via the
        // index map so the snapshot is independent of internal indexes (those are recomputed
        // on rebuild).
        var forwardEdges: [SnapshotPayload.EdgeRow] = []
        var reverseEdges: [SnapshotPayload.EdgeRow] = []
        for i in 0..<forward.nodeCount {
            guard let from = indexMap.nodeID(at: i) else { continue }
            for record in forward.neighbours(of: i) {
                forwardEdges.append(.init(from: from, to: record.toID, edgeID: record.edgeID, type: record.type))
            }
        }
        for i in 0..<reverse.nodeCount {
            guard let to = indexMap.nodeID(at: i) else { continue }
            for record in reverse.neighbours(of: i) {
                // Reverse adjacency stores the source in `record.toID` (mirroring trick from
                // CSRAdjacency.init(reverseFrom:)). Persist it back as `from`.
                reverseEdges.append(.init(from: record.toID, to: to, edgeID: record.edgeID, type: record.type))
            }
        }

        let nodeIDs = (0..<indexMap.countIncludingFreed).compactMap { indexMap.nodeID(at: $0) }
        return SnapshotPayload(
            schemaVersion: schemaVersion,
            nodeIDs: nodeIDs,
            labels: labelIndex.labelMap.mapValues(Array.init),
            forwardEdges: forwardEdges,
            reverseEdges: reverseEdges
        )
    }

    public static func materialise(
        _ payload: SnapshotPayload
    ) -> (indexMap: IndexMap, forward: CSRAdjacency, reverse: CSRAdjacency, labelIndex: LabelIndex) {
        var indexMap = IndexMap()
        for id in payload.nodeIDs { _ = indexMap.intern(id) }

        // Build CSR forward.
        var forwardFlat: [(from: Int, EdgeRecord)] = []
        for row in payload.forwardEdges {
            guard let i = indexMap.internalIndex(for: row.from) else { continue }
            forwardFlat.append((i, EdgeRecord(toID: row.to, edgeID: row.edgeID, type: row.type)))
        }
        var reverseFlat: [(from: Int, EdgeRecord)] = []
        for row in payload.reverseEdges {
            guard let i = indexMap.internalIndex(for: row.to) else { continue }
            reverseFlat.append((i, EdgeRecord(toID: row.from, edgeID: row.edgeID, type: row.type)))
        }
        let count = indexMap.countIncludingFreed
        let forward = CSRAdjacency(nodeCount: count, edges: forwardFlat)
        let reverse = CSRAdjacency(nodeCount: count, edges: reverseFlat)

        var labelIndex = LabelIndex()
        for (label, ids) in payload.labels {
            for id in ids { labelIndex.add(id, label: label) }
        }
        return (indexMap, forward, reverse, labelIndex)
    }
}

/// Atomic file writer for snapshots. Writes to `<path>.tmp` then renames.
public enum SnapshotWriter {
    public static func write(_ payload: SnapshotPayload, to url: URL) throws {
        let data = try SnapshotFormat.encode(payload)
        let tempURL = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
            // Atomic rename: replaces existing destination if present.
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tempURL, to: url)
        } catch {
            throw SnapshotError.writeFailed("\(error)")
        }
    }
}
