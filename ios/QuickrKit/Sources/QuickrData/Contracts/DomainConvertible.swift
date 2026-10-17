import Foundation

/// A wire DTO that maps to a QuickrCore domain model. Mapping throws `ContractError` when the
/// payload decodes but breaks a contract the types can't express (a malformed UUID, an unknown
/// question type, a time that isn't `HH:MM`).
public protocol DomainConvertible: Sendable {
    associatedtype Domain: Sendable
    func toDomain() throws -> Domain
}

extension Array: DomainConvertible where Element: DomainConvertible {
    public func toDomain() throws -> [Element.Domain] { try map { try $0.toDomain() } }
}

/// A response body type, with how it is read from the raw bytes.
public protocol WireResponse: Decodable, DomainConvertible {
    static func decode(_ data: Data, using decoder: JSONDecoder) throws -> Self
}

extension WireResponse {
    public static func decode(_ data: Data, using decoder: JSONDecoder) throws -> Self {
        try decoder.decode(Self.self, from: data)
    }
}

extension Array: WireResponse where Element: Decodable & DomainConvertible {}

/// The body of a request that has none, and the response of a 204.
public struct EmptyBody: Codable, Sendable, Hashable, WireResponse {
    public init() {}

    public init(from decoder: any Decoder) throws {}

    public func encode(to encoder: any Encoder) throws {}

    /// A 204 has no body; the fixtures record it as `null`.
    public static func decode(_ data: Data, using decoder: JSONDecoder) throws -> EmptyBody {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || text == "null" else {
            throw ContractError.invalid("expected an empty body, got \(data.count) bytes")
        }
        return EmptyBody()
    }

    public func toDomain() -> EmptyBody { self }
}

/// A CSV download (`exportEntriesCsv`). Not JSON, so it has no fixture.
public struct CSVBody: Sendable, Hashable, WireResponse {
    public var data: Data

    public init(data: Data) { self.data = data }

    public init(from decoder: any Decoder) throws {
        throw ContractError.invalid("CSV bodies are not JSON")
    }

    public static func decode(_ data: Data, using decoder: JSONDecoder) throws -> CSVBody { CSVBody(data: data) }

    public func toDomain() -> Data { data }
}

/// A DTO that decoded but can't be mapped to the domain.
public enum ContractError: Error, Sendable, Hashable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message): "contract violation: \(message)"
        }
    }
}

extension UUID {
    /// Lowercase canonical form, as the server writes ids and as notification identifiers require.
    public var wireString: String { uuidString.lowercased() }

    /// Parses a wire id, or throws `ContractError`.
    public static func wire(_ text: String, _ field: String) throws -> UUID {
        guard let uuid = UUID(uuidString: text) else { throw ContractError.invalid("\(field) is not a UUID: \(text)") }
        return uuid
    }
}

/// A PATCH field with three states: leave unchanged (key absent), clear (`null`), or set.
public enum Nullable<Value: Sendable & Hashable>: Sendable, Hashable {
    case absent
    case null
    case value(Value)
}

extension KeyedEncodingContainer {
    mutating func encode<Value: Encodable>(_ field: Nullable<Value>, forKey key: Key) throws {
        switch field {
        case .absent: break
        case .null: try encodeNil(forKey: key)
        case .value(let value): try encode(value, forKey: key)
        }
    }
}

extension KeyedDecodingContainer {
    func decodeNullable<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Nullable<Value> {
        guard contains(key) else { return .absent }
        if try decodeNil(forKey: key) { return .null }
        return .value(try decode(type, forKey: key))
    }
}
