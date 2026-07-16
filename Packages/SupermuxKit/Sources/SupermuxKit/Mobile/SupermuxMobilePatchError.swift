public import Foundation

/// Validation failure raised while parsing or applying a mobile write-RPC
/// patch (`project.update`, `preset.create`, `preset.update`).
///
/// Every case maps to the reserved `invalid_params` wire code; ``message``
/// is the human-readable wire `message`. These strings travel on the RPC
/// error channel (developer-facing, same policy as the other
/// `mobile.supermux.*` handler messages) — they are not UI strings.
public enum SupermuxMobilePatchError: Error, Equatable, Sendable {
    /// A required key is absent.
    case missingKey(String)
    /// The patch names a key that is not part of the wire contract. Rejected
    /// (not ignored) so a typo or a newer phone's key never silently drops
    /// part of the user's edit.
    case unknownKey(String)
    /// The patch tries to change a server-owned or immutable field.
    case immutableKey(String)
    /// The key is known but its value has the wrong type or shape.
    case invalidValue(key: String)
    /// The value is blank where a non-empty string is required.
    case emptyValue(key: String)
    /// The field is owned by the project's repo-shipped `config.json`
    /// (read-only in the desktop editor for the same reason).
    case configManagedKey(String)

    /// The wire error message (`code` is always `invalid_params`).
    public var message: String {
        switch self {
        case let .missingKey(key):
            "Required key '\(key)' is missing"
        case let .unknownKey(key):
            "Unknown patch key '\(key)'"
        case let .immutableKey(key):
            "'\(key)' cannot be changed"
        case let .invalidValue(key):
            "Invalid value for '\(key)'"
        case let .emptyValue(key):
            "'\(key)' must not be empty"
        case let .configManagedKey(key):
            "'\(key)' is managed by the project's config.json; edit that file to change it"
        }
    }
}

/// Shared `[String: Any]` value extractors for the mobile patch parsers.
///
/// Wire params arrive as JSON-decoded dictionaries: strings are `String`,
/// explicit `null` is `NSNull`, arrays are `[Any]`. "Key absent" and "key
/// present with null" are distinct on purpose — patches only touch present
/// keys, and `null` clears a nullable field.
enum SupermuxMobileWireValue {
    /// A present non-nullable string, trimmed. `nil` when the key is absent;
    /// throws on null, non-string, or (when `allowEmpty` is false) blank.
    static func string(
        _ wire: [String: Any],
        key: String,
        allowEmpty: Bool = false
    ) throws -> String? {
        guard let value = wire[key] else { return nil }
        guard let string = value as? String else {
            throw SupermuxMobilePatchError.invalidValue(key: key)
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowEmpty || !trimmed.isEmpty else {
            throw SupermuxMobilePatchError.emptyValue(key: key)
        }
        return trimmed
    }

    /// A present nullable string: `.none` when the key is absent,
    /// `.some(nil)` for an explicit `null` or blank string (both clear the
    /// field), `.some(value)` for a non-blank string.
    static func nullableString(_ wire: [String: Any], key: String) throws -> String?? {
        guard let value = wire[key] else { return .none }
        if value is NSNull { return .some(nil) }
        guard let string = value as? String else {
            throw SupermuxMobilePatchError.invalidValue(key: key)
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return .some(trimmed.isEmpty ? nil : trimmed)
    }

    /// A present array of strings, entries trimmed and empties dropped
    /// (mirroring the `config.json` import's cleaning). `nil` when absent.
    static func stringArray(_ wire: [String: Any], key: String) throws -> [String]? {
        guard let value = wire[key] else { return nil }
        guard let array = value as? [Any] else {
            throw SupermuxMobilePatchError.invalidValue(key: key)
        }
        var strings: [String] = []
        strings.reserveCapacity(array.count)
        for element in array {
            guard let string = element as? String else {
                throw SupermuxMobilePatchError.invalidValue(key: key)
            }
            strings.append(string)
        }
        return SupermuxProjectConfig.cleaned(strings)
    }
}
