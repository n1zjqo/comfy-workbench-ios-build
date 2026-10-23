import Foundation

/// A typed JSON tree. Integers never pass through Double, including UInt64 seeds.
public enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case decimal(Double)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(UInt64.self) { self = .unsignedInteger(value) }
        else if let value = try? container.decode(Double.self), value.isFinite { self = .decimal(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsignedInteger(let value): try container.encode(value)
        case .decimal(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public init(data: Data) throws { self = try JSONDecoder().decode(JSONValue.self, from: data) }

    public func data(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }

    public var integerValue: Int64? {
        switch self {
        case .integer(let value): return value
        case .unsignedInteger(let value): return Int64(exactly: value)
        default: return nil
        }
    }

    public var uint64Value: UInt64? {
        switch self {
        case .integer(let value): return UInt64(exactly: value)
        case .unsignedInteger(let value): return value
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .unsignedInteger(let value): return Double(value)
        case .decimal(let value): return value
        default: return nil
        }
    }

    public var isScalar: Bool {
        switch self { case .array, .object: return false; default: return true }
    }

    public var displayValue: String {
        switch self {
        case .null: return "null"
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .unsignedInteger(let value): return String(value)
        case .decimal(let value): return String(value)
        case .array, .object: return (try? String(data: data(), encoding: .utf8)) ?? ""
        }
    }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}
