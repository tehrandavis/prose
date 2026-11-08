import Foundation

public enum JSONValue: Codable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue {
        if case let .object(value) = self {
            value[key] ?? .null
        } else {
            .null
        }
    }

    public var string: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }

    public var int: Int? {
        if case let .number(value) = self {
            Int(exactly: value)
        } else {
            nil
        }
    }

    public var array: [JSONValue] {
        if case let .array(value) = self {
            value
        } else {
            []
        }
    }

    public var isNull: Bool {
        if case .null = self {
            true
        } else {
            false
        }
    }

    public var foundationValue: Any {
        switch self {
        case let .object(value): value.mapValues(\.foundationValue)
        case let .array(value): value.map(\.foundationValue)
        case let .string(value): value
        case let .number(value): value
        case let .bool(value): value
        case .null: NSNull()
        }
    }
}
