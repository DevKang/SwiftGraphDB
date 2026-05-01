import Foundation

/// Shared, deterministic encoder/decoder for the `properties` BLOB column on nodes and edges.
///
/// Determinism matters: the same property dictionary must produce byte-identical SQLite BLOBs so
/// CloudKit sync diffing and content-addressed indexes don't see spurious changes. `.sortedKeys`
/// is the load-bearing flag here — `PropertyValue`'s own Codable produces a stable shape per key
/// (see `PropertyValueTests.testEncodingShapeIsTaggedUnion`).
enum PropertyCoding {

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder = JSONDecoder()

    static func encode(_ properties: [String: PropertyValue]) throws -> Data {
        try encoder.encode(properties)
    }

    static func decode(_ data: Data) throws -> [String: PropertyValue] {
        try decoder.decode([String: PropertyValue].self, from: data)
    }
}
