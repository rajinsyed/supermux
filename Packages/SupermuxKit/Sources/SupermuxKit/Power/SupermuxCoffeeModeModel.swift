public import Foundation
public import Observation

/// Owns Coffee Mode's persisted state and app-scoped keep-awake assertion.
///
/// One instance is composed by the macOS app and shared by every window. The
/// persisted flag records user intent; when it is on, the model reacquires the
/// assertion at app launch.
@MainActor
@Observable
public final class SupermuxCoffeeModeModel {
    /// Whether Coffee Mode is switched on.
    public private(set) var isEnabled = false

    /// What macOS is actually delivering for the current enabled state.
    public private(set) var coverage: SupermuxCoffeeModeCoverage = .off

    @ObservationIgnored private let assertion: any SupermuxKeepAwakeAsserting
    @ObservationIgnored private let defaults: UserDefaults

    /// The `UserDefaults` key storing Coffee Mode's persisted enabled state.
    public static let enabledDefaultsKey = "supermux.coffeeMode.enabled"

    /// Creates the Coffee Mode model and restores its persisted state.
    ///
    /// - Parameters:
    ///   - assertion: Assertion holder used to keep the Mac from idle-sleeping.
    ///   - defaults: Defaults store containing the persisted enabled flag.
    public init(
        assertion: any SupermuxKeepAwakeAsserting,
        defaults: UserDefaults
    ) {
        self.assertion = assertion
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        if isEnabled {
            acquireAndPublish()
        }
    }

    /// Toggles Coffee Mode between enabled and disabled.
    public func toggle() {
        setEnabled(!isEnabled)
    }

    /// Sets Coffee Mode to the requested state.
    ///
    /// A failed release leaves every signal visibly on—model state, persisted
    /// state, icon, and tooltip—because the Mac is still being kept awake. The
    /// next disable attempt retries the same assertion ID.
    ///
    /// - Parameter enabled: Whether Coffee Mode should be enabled.
    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            commitEnabled(true)
            acquireAndPublish()
            return
        }

        guard assertion.release() else {
            coverage = SupermuxCoffeeModeCoverage(
                isActive: true,
                keepsSystemAwake: true
            )
            return
        }
        commitEnabled(false)
        coverage = .off
    }

    private func acquireAndPublish() {
        coverage = SupermuxCoffeeModeCoverage(
            isActive: true,
            keepsSystemAwake: assertion.acquire()
        )
    }

    private func commitEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
    }
}
