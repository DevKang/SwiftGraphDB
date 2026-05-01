import Foundation

/// A typed value attached to a node or edge.
///
/// `PropertyValue` is the storage type for every entry in a node's or edge's `properties` dictionary.
/// It is the only value shape that is allowed to round-trip through SQLite, JSON, and (eventually)
/// CloudKit, so its serialised form is held stable by tests in `PropertyValueTests`.
///
/// ## JSON encoding shape
///
/// Encoding produces a tagged union of the form `{"type": <case>, "value": <payload>}`. `null` has
/// no `value` field. The `type` strings are part of the on-disk format — do not rename them without
/// a schema migration.
///
/// ```json
/// {"type": "string", "value": "alice"}
/// {"type": "int",    "value": 42}
/// {"type": "null"}
/// {"type": "array",  "value": [{"type": "int", "value": 1}, ...]}
/// ```
///
/// ## Equality semantics
///
/// `.double(.nan)` is *not* equal to itself, matching `Double`. Document this when consuming.
public enum PropertyValue: Hashable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case array([PropertyValue])
    case null
}

// MARK: - Codable (custom tagged union)

extension PropertyValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum Tag: String, Codable {
        case string, int, double, bool, date, data, array, null
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let s):
            try container.encode(Tag.string, forKey: .type)
            try container.encode(s, forKey: .value)
        case .int(let i):
            try container.encode(Tag.int, forKey: .type)
            try container.encode(i, forKey: .value)
        case .double(let d):
            try container.encode(Tag.double, forKey: .type)
            try container.encode(d, forKey: .value)
        case .bool(let b):
            try container.encode(Tag.bool, forKey: .type)
            try container.encode(b, forKey: .value)
        case .date(let d):
            try container.encode(Tag.date, forKey: .type)
            // Encode as milliseconds since epoch so on-disk precision is documented and
            // deterministic across encoder configurations.
            try container.encode(Int64((d.timeIntervalSince1970 * 1000).rounded()), forKey: .value)
        case .data(let bytes):
            try container.encode(Tag.data, forKey: .type)
            try container.encode(bytes, forKey: .value)
        case .array(let items):
            try container.encode(Tag.array, forKey: .type)
            try container.encode(items, forKey: .value)
        case .null:
            try container.encode(Tag.null, forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(Tag.self, forKey: .type)
        switch tag {
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        case .int:    self = .int(try container.decode(Int64.self, forKey: .value))
        case .double: self = .double(try container.decode(Double.self, forKey: .value))
        case .bool:   self = .bool(try container.decode(Bool.self, forKey: .value))
        case .date:
            let ms = try container.decode(Int64.self, forKey: .value)
            self = .date(Date(timeIntervalSince1970: Double(ms) / 1000))
        case .data:   self = .data(try container.decode(Data.self, forKey: .value))
        case .array:  self = .array(try container.decode([PropertyValue].self, forKey: .value))
        case .null:   self = .null
        }
    }
}

// MARK: - Literal conformances (Quick Start ergonomics)

extension PropertyValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension PropertyValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension PropertyValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension PropertyValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension PropertyValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
