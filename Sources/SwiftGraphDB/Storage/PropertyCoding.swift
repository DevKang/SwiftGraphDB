import Foundation

/// Shared, deterministic encoder/decoder for the `properties` TEXT column on nodes and edges.
///
/// Determinism matters: the same property dictionary must produce identical JSON strings so
/// CloudKit sync diffing and content-addressed indexes don't see spurious changes. `.sortedKeys`
/// is the load-bearing flag here — `PropertyValue`'s own Codable produces a stable shape per key
/// (see `PropertyValueTests.testEncodingShapeIsTaggedUnion`).
///
/// Since migration v3 the column type is TEXT (not BLOB), enabling SQLite `json_extract()` for
/// server-side filtering, sorting, and pagination.
enum PropertyCoding {

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder = JSONDecoder()

    // MARK: - Data (legacy / change_journal payload)

    static func encode(_ properties: [String: PropertyValue]) throws -> Data {
        try encoder.encode(properties)
    }

    static func decode(_ data: Data) throws -> [String: PropertyValue] {
        try decoder.decode([String: PropertyValue].self, from: data)
    }

    // MARK: - String (v3+ properties TEXT column)

    static func encodeToString(_ properties: [String: PropertyValue]) throws -> String {
        let data = try encoder.encode(properties)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decodeFromString(_ text: String) throws -> [String: PropertyValue] {
        guard let data = text.data(using: .utf8) else {
            throw RepositoryError.malformedRow
        }
        return try decoder.decode([String: PropertyValue].self, from: data)
    }
}
