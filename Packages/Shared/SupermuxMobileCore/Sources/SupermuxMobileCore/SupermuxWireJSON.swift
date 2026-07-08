import Foundation

/// Bridges the package's Codable DTOs to and from `[String: Any]`
/// dictionaries.
///
/// The Mac's RPC dispatch speaks dictionaries while the phone speaks typed
/// DTOs; both sides encode/decode through the SAME DTO type via this bridge,
/// so the wire shape has exactly one definition. Uses plain
/// `JSONEncoder`/`JSONDecoder` with no key or date strategy — the DTOs carry
/// snake_case in their own `CodingKeys` and travel dates as Unix seconds.
///
/// ```swift
/// let wire = SupermuxWireJSON()
/// let payload = try wire.dictionary(from: projectDTO)      // Mac → RPC result
/// let dto = try wire.decode(SupermuxProjectDTO.self,
///                           from: payload)                 // params → DTO
/// ```
public struct SupermuxWireJSON: Sendable {
    /// Creates a bridge. Stateless; construct wherever needed.
    public init() {}

    /// Encodes a DTO into a JSON-object dictionary.
    /// - Parameter value: The DTO to encode.
    /// - Returns: The DTO's JSON object as `[String: Any]`.
    /// - Throws: ``SupermuxWireJSONError/notADictionary`` when the value does
    ///   not encode to a JSON object, or any underlying `EncodingError`.
    public func dictionary<Value: Encodable>(from value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dictionary = object as? [String: Any] else {
            throw SupermuxWireJSONError.notADictionary
        }
        return dictionary
    }

    /// Decodes a DTO from a JSON-object dictionary, tolerating unknown keys.
    /// - Parameters:
    ///   - type: The DTO type to decode.
    ///   - dictionary: A JSON object as `[String: Any]`.
    /// - Returns: The decoded DTO.
    /// - Throws: Any `JSONSerialization` or `DecodingError` failure.
    public func decode<Value: Decodable>(
        _ type: Value.Type,
        from dictionary: [String: Any]
    ) throws -> Value {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return try JSONDecoder().decode(type, from: data)
    }
}
