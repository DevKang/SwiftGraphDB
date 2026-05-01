import Foundation

public enum PropertyValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case array([PropertyValue])
    case null
}
