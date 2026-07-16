/// Errors ``SupermuxWireJSON`` throws beyond the underlying coding errors.
public enum SupermuxWireJSONError: Error, Equatable, Sendable {
    /// The encoded value is not a JSON object (e.g. a bare scalar or array),
    /// so it cannot bridge to `[String: Any]`.
    case notADictionary
}
