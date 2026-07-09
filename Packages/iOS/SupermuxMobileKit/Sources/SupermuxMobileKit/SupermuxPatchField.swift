public import Foundation

/// One nullable field of a `mobile.supermux.*.update` patch: either a new
/// value or an explicit clear.
///
/// The Mac's patch parser distinguishes an ABSENT key (field untouched) from
/// an explicit `null` (field cleared), so an `Optional<Value>` cannot model a
/// present field — `nil` would be ambiguous. Patches hold
/// `SupermuxPatchField?`: `nil` = key absent, `.set` = new value, `.clear` =
/// wire `null`.
public enum SupermuxPatchField<Value: Equatable & Sendable>: Equatable, Sendable {
    /// The field gets this new value.
    case set(Value)
    /// The field is cleared (travels as JSON `null`).
    case clear

    /// The JSON-object value for this field: the wrapped value, or `NSNull`
    /// for a clear.
    var wireValue: Any {
        switch self {
        case let .set(value): value
        case .clear: NSNull()
        }
    }

    /// Builds the field from a nullable "edited" value against a nullable
    /// "original": `nil` (no key) when they are equal, `.clear` when the edit
    /// removes a present value, `.set` when it changes or introduces one.
    ///
    /// - Parameters:
    ///   - edited: The edited value (`nil` = cleared by the user).
    ///   - original: The original value (`nil` = was never set).
    static func diff(from original: Value?, to edited: Value?) -> SupermuxPatchField? {
        guard edited != original else { return nil }
        guard let edited else { return original == nil ? nil : .clear }
        return .set(edited)
    }
}
