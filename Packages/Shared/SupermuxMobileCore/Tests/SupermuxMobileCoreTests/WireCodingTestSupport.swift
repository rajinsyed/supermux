import Foundation
@testable import SupermuxMobileCore

/// Shared coding helpers for the DTO test suites: plain encoder/decoder
/// round-trips (no key strategy — the DTOs must carry snake_case in their own
/// CodingKeys) plus top-level JSON key inspection.
struct WireCodingTestSupport {
    /// Decodes a DTO from a JSON fixture string using a plain `JSONDecoder`.
    func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// Encodes then decodes the value, returning the round-tripped copy.
    func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    /// The top-level JSON object keys a plain `JSONEncoder` produces.
    func encodedKeys<Value: Encodable>(of value: Value) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { return [] }
        return Set(dictionary.keys)
    }
}
