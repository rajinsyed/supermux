public import Foundation
public import Observation

/// App-wide model behind the sidebar Coffee Mode toggle: holds the keep-awake
/// power assertions while enabled so long-running agents are not cut off by the
/// Mac going to sleep.
///
/// Ownership follows the same pattern as ``SupermuxUsageModel`` — one instance
/// in the composition root, shared by every window's sidebar footer, with the
/// state living here rather than in the view so all windows agree.
///
/// Persistence is deliberate: an agent left running overnight should survive an
/// app restart with Coffee Mode still on, so the flag is stored in
/// `UserDefaults` and re-applied at launch.
@MainActor
@Observable
public final class SupermuxCoffeeModeModel {
    /// The user's intent. `coverage` describes what macOS actually granted,
    /// which can be less (see ``SupermuxCoffeeModeCoverage/isDegraded``).
    public private(set) var isEnabled = false
    public private(set) var coverage: SupermuxCoffeeModeCoverage = .off

    @ObservationIgnored private let assertions: any SupermuxKeepAwakeAsserting
    @ObservationIgnored private let defaults: UserDefaults
    /// `nil` in tests, which drive `refreshForPowerSourceChange()` directly
    /// instead of waiting on a real plug/unplug.
    @ObservationIgnored private let powerSourceMonitor: (any SupermuxPowerSourceObserving)?

    public static let enabledDefaultsKey = "supermux.coffeeMode.enabled"

    public init(
        assertions: any SupermuxKeepAwakeAsserting = SupermuxKeepAwakeAssertions(),
        defaults: UserDefaults = .standard,
        powerSourceMonitor: (any SupermuxPowerSourceObserving)? = SupermuxPowerSourceMonitor()
    ) {
        self.assertions = assertions
        self.defaults = defaults
        self.powerSourceMonitor = powerSourceMonitor
        self.isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        if isEnabled {
            // Observe BEFORE sampling: registering second would miss an unplug
            // landing between the sample and registration, leaving coverage
            // permanently stale.
            startObservingPowerSource()
            applyAssertions()
        }
    }

    public func toggle() {
        setEnabled(!isEnabled)
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            commitEnabled(true)
            startObservingPowerSource()
            applyAssertions()
            return
        }

        // Release BEFORE committing the flag. If `powerd` refuses a release the
        // Mac is still being kept awake, so the mode must stay visibly on —
        // icon, tooltip and persisted flag all agreeing — instead of showing
        // Off over a live assertion. The user's next toggle retries the
        // release, because `isEnabled` never went false.
        let stillHeld = assertions.releaseAll()
        guard stillHeld.isEmpty else {
            coverage = SupermuxCoffeeModeCoverage(
                isActive: true,
                powerSource: assertions.currentPowerSource(),
                heldLayers: stillHeld
            )
            return
        }
        commitEnabled(false)
        powerSourceMonitor?.stop()
        coverage = .off
    }

    private func commitEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
    }

    /// True when plug/unplug is observable. If the run-loop source cannot be
    /// created, an unplug would go unnoticed and the AC-only layer would sit
    /// there inert while coverage still counted it — so `applyAssertions()`
    /// withholds that layer entirely rather than report protection that a
    /// later unplug would silently remove.
    @ObservationIgnored private var isObservingPowerSource = false

    private func startObservingPowerSource() {
        guard let powerSourceMonitor else {
            // No monitor injected (tests drive refreshes directly).
            isObservingPowerSource = true
            return
        }
        isObservingPowerSource = powerSourceMonitor.start { [weak self] in
            self?.refreshForPowerSourceChange()
        }
    }

    /// Re-evaluates coverage against the current power source. Called when the
    /// Mac is plugged in or unplugged: the lid-close layer is AC-only, so
    /// unplugging must drop it (and update the tooltip) rather than leave the
    /// UI claiming coverage the Mac no longer has.
    public func refreshForPowerSourceChange() {
        guard isEnabled else { return }
        applyAssertions()
    }

    private func applyAssertions() {
        // Downgrade to battery semantics when plug/unplug is unobservable: the
        // AC-only layer would be counted as coverage and then silently go inert
        // the moment the user unplugged, with nothing to notice it.
        let powerSource = isObservingPowerSource ? assertions.currentPowerSource() : .battery
        let granted = assertions.acquire(SupermuxKeepAwakeLayer.requested(for: powerSource))
        coverage = SupermuxCoffeeModeCoverage(
            isActive: true,
            powerSource: powerSource,
            heldLayers: granted
        )
    }
}
