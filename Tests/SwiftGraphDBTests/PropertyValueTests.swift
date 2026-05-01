import XCTest
@testable import SwiftGraphDB

final class PropertyValueTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let original: PropertyValue = .array([
            .string("hello"),
            .int(42),
            .double(3.14),
            .bool(true),
            .null,
        ])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PropertyValue.self, from: data)

        XCTAssertEqual(original, decoded)
    }
}
