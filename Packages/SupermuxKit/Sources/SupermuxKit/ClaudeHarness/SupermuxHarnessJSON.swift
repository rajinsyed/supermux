public import Foundation

/// An immutable JSON object decoded from or encoded to the Claude Code stream protocol.
///
/// The Foundation dictionary is preserved for direct WebKit bridge pass-through. Values come from
/// `JSONSerialization` without mutable-container options, so the stored object graph is immutable.
public struct SupermuxHarnessJSONObject: @unchecked Sendable {
    private let storage: [String: Any]

    /// Creates an immutable object from a Foundation JSON dictionary.
    ///
    /// - Parameter rawValue: A dictionary accepted by `JSONSerialization`.
    /// - Throws: ``SupermuxHarnessProtocolError/invalidJSONObject`` when the dictionary is not JSON.
    public init(rawValue: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(rawValue) else {
            throw SupermuxHarnessProtocolError.invalidJSONObject
        }
        let data = try JSONSerialization.data(withJSONObject: rawValue, options: [.sortedKeys])
        guard let frozen = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SupermuxHarnessProtocolError.invalidJSONObject
        }
        storage = frozen
    }

    init(parsedObject: [String: Any]) {
        storage = parsedObject
    }

    /// Returns the preserved Foundation dictionary for bridge pass-through.
    public var rawValue: [String: Any] {
        storage
    }

    /// Returns a string property when the value has the expected type.
    ///
    /// - Parameter key: The property name.
    /// - Returns: The string value, or `nil`.
    public func string(forKey key: String) -> String? {
        storage[key] as? String
    }

    /// Returns a Boolean property when the value has the expected type.
    ///
    /// - Parameter key: The property name.
    /// - Returns: The Boolean value, or `nil`.
    public func bool(forKey key: String) -> Bool? {
        storage[key] as? Bool
    }

    /// Returns an integer property when the JSON number is integral.
    ///
    /// - Parameter key: The property name.
    /// - Returns: The integer value, or `nil`.
    public func integer(forKey key: String) -> Int? {
        guard let number = storage[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        var value = number.decimalValue
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        guard rounded == value,
              value >= Decimal(Int.min),
              value <= Decimal(Int.max) else {
            return nil
        }
        return number.intValue
    }

    /// Returns a nested object property.
    ///
    /// - Parameter key: The property name.
    /// - Returns: The nested object, or `nil`.
    public func object(forKey key: String) -> SupermuxHarnessJSONObject? {
        guard let object = storage[key] as? [String: Any] else { return nil }
        return SupermuxHarnessJSONObject(parsedObject: object)
    }

    /// Returns the object entries from an array property, dropping non-object entries.
    ///
    /// - Parameter key: The property name.
    /// - Returns: The nested objects, or `nil` when the property is not an array.
    public func objects(forKey key: String) -> [SupermuxHarnessJSONObject]? {
        guard let values = storage[key] as? [Any] else { return nil }
        return values.compactMap { value in
            guard let object = value as? [String: Any] else { return nil }
            return SupermuxHarnessJSONObject(parsedObject: object)
        }
    }

    /// Serializes the object to deterministic JSON data.
    ///
    /// - Returns: UTF-8 JSON with keys sorted for stable tests and logging.
    /// - Throws: A Foundation serialization error if the preserved object cannot be encoded.
    public func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: storage, options: [.sortedKeys])
    }

    subscript(key: String) -> Any? {
        storage[key]
    }
}

extension SupermuxHarnessJSONObject: Equatable {
    /// Compares objects by their JSON value rather than Foundation container identity.
    public static func == (lhs: SupermuxHarnessJSONObject, rhs: SupermuxHarnessJSONObject) -> Bool {
        guard let lhsData = try? lhs.jsonData(), let rhsData = try? rhs.jsonData() else {
            return false
        }
        return lhsData == rhsData
    }
}
