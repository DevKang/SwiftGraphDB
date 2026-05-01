import XCTest
@testable import SwiftGraphDB

final class PropertyValueTests: XCTestCase {

    // MARK: - Codable round-trip per case

    func testStringRoundTrip() throws { try roundTrip(.string("hello")) }
    func testEmptyStringRoundTrip() throws { try roundTrip(.string("")) }
    func testIntRoundTrip() throws { try roundTrip(.int(42)) }
    func testNegativeIntRoundTrip() throws { try roundTrip(.int(-9_223_372_036_854_775_807)) }
    func testDoubleRoundTrip() throws { try roundTrip(.double(3.14159)) }
    func testBoolRoundTrip() throws { try roundTrip(.bool(true)); try roundTrip(.bool(false)) }
    func testNullRoundTrip() throws { try roundTrip(.null) }

    func testNestedArrayRoundTrip() throws {
        let original: PropertyValue = .array([
            .string("hello"),
            .int(42),
            .null,
            .array([.bool(true), .double(2.5)]),
        ])
        try roundTrip(original)
    }

    // MARK: - Date round trip with millisecond precision

    func testDateRoundTripWithMillisecondPrecision() throws {
        // Date uses Double seconds since reference; millisecond precision = 0.001s.
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let original: PropertyValue = .date(date)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PropertyValue.self, from: data)
        guard case .date(let roundTripped) = decoded else {
            return XCTFail("Expected .date, got \(decoded)")
        }
        XCTAssertEqual(roundTripped.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Data round trip

    func testEmptyDataRoundTrip() throws {
        try roundTrip(.data(Data()))
    }

    func testRandomDataRoundTrip() throws {
        let bytes = Data((0..<1024).map { _ in UInt8.random(in: .min ... .max) })
        try roundTrip(.data(bytes))
    }

    // MARK: - Equality and hashing

    func testEqualValuesProduceEqualHashes() {
        let a: PropertyValue = .string("alice")
        let b: PropertyValue = .string("alice")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)

        // Dictionary keying works.
        var dict: [PropertyValue: Int] = [:]
        dict[a] = 1
        dict[b] = 2
        XCTAssertEqual(dict.count, 1)
        XCTAssertEqual(dict[a], 2)
    }

    func testSetDeduplicatesByValue() {
        let s: Set<PropertyValue> = [.int(1), .int(1), .int(2), .string("1")]
        XCTAssertEqual(s.count, 3) // .int(1), .int(2), .string("1")
    }

    func testNaNIsNotEqualToItself() {
        // Document the policy: matches Double semantics.
        let nan: PropertyValue = .double(.nan)
        XCTAssertNotEqual(nan, nan)
    }

    // MARK: - Literal initialisers

    func testStringLiteral() {
        let v: PropertyValue = "alice"
        XCTAssertEqual(v, .string("alice"))
    }

    func testIntegerLiteral() {
        let v: PropertyValue = 42
        XCTAssertEqual(v, .int(42))
    }

    func testFloatLiteral() {
        let v: PropertyValue = 3.5
        XCTAssertEqual(v, .double(3.5))
    }

    func testBooleanLiteral() {
        let v: PropertyValue = true
        XCTAssertEqual(v, .bool(true))
    }

    func testNilLiteral() {
        let v: PropertyValue = nil
        XCTAssertEqual(v, .null)
    }

    func testReadmeDictionaryLiteralCompiles() {
        // Mirrors the README Quick Start example.
        let _: [String: PropertyValue] = ["name": "Alice", "age": 32]
    }

    // MARK: - Deterministic encoding

    func testEncodingIsDeterministicForSameValue() throws {
        let value: PropertyValue = .array([
            .string("a"), .int(1), .bool(false), .null,
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(value)
        let second = try encoder.encode(value)
        XCTAssertEqual(first, second)
    }

    func testEncodingShapeIsTaggedUnion() throws {
        // The shape is documented; protect it with a test so any future
        // accidental shape change shows up here, not in user data.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(PropertyValue.int(42))
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        XCTAssertEqual(decoded?["type"] as? String, "int")
        XCTAssertEqual(decoded?["value"] as? Int, 42)
    }

    // MARK: - Helpers

    private func roundTrip(_ original: PropertyValue, file: StaticString = #file, line: UInt = #line) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(PropertyValue.self, from: data)
        XCTAssertEqual(original, decoded, file: file, line: line)
    }
}
