import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Abstracts the IOKit power-assertion calls so ``SupermuxCoffeeModeModel`` is
/// testable without changing the test machine's real power behavior.
public protocol SupermuxKeepAwakeAsserting: Sendable {
    /// Reads the current power source. Coffee Mode re-reads this on every
    /// acquire and whenever the source changes while active.
    func currentPowerSource() -> SupermuxPowerSource

    /// Requests every layer in `layers`, returning only those actually granted.
    /// Never throws: a refused layer is simply absent from the result, which is
    /// what lets the UI degrade honestly.
    func acquire(_ layers: [SupermuxKeepAwakeLayer]) -> Set<SupermuxKeepAwakeLayer>

    /// Releases everything currently held and returns whatever is STILL held
    /// afterwards — empty on success. A non-empty result means `powerd` refused
    /// a release, so the Mac is still being kept awake and the UI must not
    /// claim the mode is off. Safe to call when nothing is held.
    @discardableResult
    func releaseAll() -> Set<SupermuxKeepAwakeLayer>
}

/// The real IOKit implementation.
///
/// Deliberately assertion-based rather than `pmset disablesleep`:
/// `IOPMSetSystemPowerSetting` hard-fails for non-root (`getuid() != 0` →
/// `kIOReturnNotPrivileged`) and persists `SleepDisabled` into
/// `/Library/Preferences/com.apple.PowerManagement.plist`, which `powerd`
/// re-applies at boot — so a crash would leave the Mac permanently unable to
/// sleep. Assertions need no privileges and `powerd` releases them
/// automatically when the owning process exits, dies, or is SIGKILLed.
public final class SupermuxKeepAwakeAssertions: SupermuxKeepAwakeAsserting, @unchecked Sendable {
    /// Guards `assertionIDs`; the model is `@MainActor` but the lock keeps this
    /// type independently safe and satisfies `Sendable` without actor hops.
    private let lock = NSLock()
    private var assertionIDs: [SupermuxKeepAwakeLayer: IOPMAssertionID] = [:]

    public init() {}

    public func currentPowerSource() -> SupermuxPowerSource {
        // `IOPSGet…` is a Get-rule (+0) function returning one of the CFSTR
        // constants — takeUnretainedValue, never takeRetainedValue, which
        // would over-release a constant.
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String? else {
            return .unknown
        }
        switch type {
        case kIOPMBatteryPowerKey: return .battery
        case kIOPMACPowerKey: return .ac
        default: return .unknown
        }
    }

    public func acquire(_ layers: [SupermuxKeepAwakeLayer]) -> Set<SupermuxKeepAwakeLayer> {
        lock.lock()
        defer { lock.unlock() }

        // Drop any layer no longer requested (e.g. the AC-only deep-sleep layer
        // after unplugging) so held state never overstates coverage. Keep the
        // ID when the release fails: dropping it would orphan a live assertion
        // that nothing could release until the process exits.
        for (layer, id) in assertionIDs where !layers.contains(layer) {
            if IOPMAssertionRelease(id) == kIOReturnSuccess {
                assertionIDs[layer] = nil
            }
        }

        for layer in layers where assertionIDs[layer] == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                layer.assertionTypeName as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                Self.assertionReason as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertionIDs[layer] = id
            }
        }
        // Only the requested layers count as coverage; a layer retained above
        // because its release failed is still held by powerd but is no longer
        // something the UI should report.
        return Set(assertionIDs.keys).intersection(layers)
    }

    @discardableResult
    public func releaseAll() -> Set<SupermuxKeepAwakeLayer> {
        lock.lock()
        defer { lock.unlock() }
        // Retain any ID whose release failed so a later attempt can still let
        // it go, instead of leaking an assertion that keeps the Mac awake.
        assertionIDs = assertionIDs.filter { IOPMAssertionRelease($0.value) != kIOReturnSuccess }
        return Set(assertionIDs.keys)
    }

    /// Shown to the user in `pmset -g assertions` and Activity Monitor's
    /// "Preventing Sleep" column, so it names the app and the feature.
    private static let assertionReason = "Supermux Coffee Mode"

    deinit {
        for id in assertionIDs.values {
            IOPMAssertionRelease(id)
        }
    }
}
