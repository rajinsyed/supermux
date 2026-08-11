/// Acquires and releases Coffee Mode's idle-system-sleep assertion.
///
/// The protocol keeps ``SupermuxCoffeeModeModel`` testable without changing the
/// test Mac's real power behavior.
@MainActor
public protocol SupermuxKeepAwakeAsserting: AnyObject {
    /// Acquires the keep-awake assertion if it is not already held.
    ///
    /// - Returns: `true` when the assertion is held after the call.
    func acquire() -> Bool

    /// Releases the keep-awake assertion if one is held.
    ///
    /// - Returns: `true` when no assertion remains held after the call.
    func release() -> Bool
}
