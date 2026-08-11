import Foundation
import IOKit.pwr_mgt

/// Holds the public IOKit assertion used by Coffee Mode.
///
/// This is deliberately assertion-based rather than `pmset disablesleep`.
/// `pmset` requires root and persists `SleepDisabled` across app exits and
/// reboots, while IOKit assertions need no privileges and `powerd` releases
/// them automatically when the owning process exits, dies, or is killed.
///
/// Only `PreventUserIdleSystemSleep` is used. Keeping the display awake is not
/// necessary for agents to keep running and would waste power; explicit sleep,
/// lid close, and critical-battery sleep remain normal macOS behavior.
///
/// Main-actor isolation matches the owning ``SupermuxCoffeeModeModel`` and
/// serializes the synchronous C assertion handle without a lock.
@MainActor
public final class SupermuxKeepAwakeAssertion: SupermuxKeepAwakeAsserting {
    private var assertionID: IOPMAssertionID?

    /// Creates an assertion holder with no active assertion.
    public init() {}

    /// Acquires the idle-system-sleep assertion if needed.
    ///
    /// - Returns: `true` when the assertion is held after the call.
    public func acquire() -> Bool {
        if assertionID != nil {
            return true
        }

        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Supermux Coffee Mode" as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            return false
        }
        assertionID = id
        return true
    }

    /// Releases the idle-system-sleep assertion if held.
    ///
    /// A failed release intentionally retains the ID so the next toggle can
    /// retry rather than orphaning a live assertion until process exit.
    ///
    /// - Returns: `true` when no assertion remains held after the call.
    public func release() -> Bool {
        guard let assertionID else {
            return true
        }
        guard IOPMAssertionRelease(assertionID) == kIOReturnSuccess else {
            return false
        }
        self.assertionID = nil
        return true
    }

    deinit {
        if let assertionID {
            IOPMAssertionRelease(assertionID)
        }
    }
}
