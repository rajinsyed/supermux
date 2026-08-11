import Foundation
import Testing

@testable import SupermuxKit

/// Records what was asked of IOKit and lets a test refuse specific layers, so
/// the honesty rules can be exercised without changing the machine's real
/// power behavior.
private final class StubKeepAwakeAssertions: SupermuxKeepAwakeAsserting, @unchecked Sendable {
    var powerSource: SupermuxPowerSource
    /// Layers macOS will refuse; everything else requested is granted.
    var refusedLayers: Set<SupermuxKeepAwakeLayer>

    /// Layers whose RELEASE powerd will refuse, simulating a failed
    /// IOPMAssertionRelease that leaves the Mac still awake.
    var unreleasableLayers: Set<SupermuxKeepAwakeLayer> = []

    private(set) var acquireCalls: [[SupermuxKeepAwakeLayer]] = []
    private(set) var releaseAllCount = 0
    private(set) var held: Set<SupermuxKeepAwakeLayer> = []

    init(
        powerSource: SupermuxPowerSource = .ac,
        refusedLayers: Set<SupermuxKeepAwakeLayer> = []
    ) {
        self.powerSource = powerSource
        self.refusedLayers = refusedLayers
    }

    func currentPowerSource() -> SupermuxPowerSource { powerSource }

    func acquire(_ layers: [SupermuxKeepAwakeLayer]) -> Set<SupermuxKeepAwakeLayer> {
        acquireCalls.append(layers)
        held = Set(layers).subtracting(refusedLayers)
        return held
    }

    @discardableResult
    func releaseAll() -> Set<SupermuxKeepAwakeLayer> {
        releaseAllCount += 1
        held = held.intersection(unreleasableLayers)
        return held
    }
}

@MainActor
private func makeModel(
    _ assertions: StubKeepAwakeAssertions,
    persisted: Bool = false
) -> (SupermuxCoffeeModeModel, UserDefaults) {
    let suiteName = "supermux.coffee.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(persisted, forKey: SupermuxCoffeeModeModel.enabledDefaultsKey)
    // No power-source monitor: tests drive `refreshForPowerSourceChange()`
    // directly rather than waiting on a real plug/unplug run-loop event.
    let model = SupermuxCoffeeModeModel(
        assertions: assertions,
        defaults: defaults,
        powerSourceMonitor: nil
    )
    return (model, defaults)
}

@Suite("Coffee Mode layer selection")
struct SupermuxCoffeeModeLayerTests {
    @Test("AC power requests the deep-sleep layer alongside both idle layers")
    func acRequestsAllThree() {
        #expect(SupermuxKeepAwakeLayer.requested(for: .ac) == [
            .idleSystemSleep, .idleDisplaySleep, .systemSleep,
        ])
    }

    /// PreventSystemSleep is marked `kAssertionTypeNotValidOnBatt` by powerd,
    /// so requesting it on battery would report coverage the Mac lacks.
    @Test("Battery omits the AC-only deep-sleep layer")
    func batteryOmitsSystemSleep() {
        #expect(SupermuxKeepAwakeLayer.requested(for: .battery) == [
            .idleSystemSleep, .idleDisplaySleep,
        ])
    }

    /// An unreadable power source must NOT get the AC-only layer:
    /// IOPMAssertionCreateWithName succeeds even for a layer powerd marks
    /// NotValidOnBatt, so an inert assertion looks identical to a working one
    /// and coverage would overpromise on a battery Mac.
    @Test("Unknown power source withholds the AC-only layer")
    func unknownWithholdsSystemSleep() {
        #expect(!SupermuxPowerSource.unknown.allowsSystemSleepAssertion)
        #expect(SupermuxKeepAwakeLayer.requested(for: .unknown) == [
            .idleSystemSleep, .idleDisplaySleep,
        ])
    }

    @Test("Battery does not allow the system-sleep assertion")
    func batteryDisallows() {
        #expect(!SupermuxPowerSource.battery.allowsSystemSleepAssertion)
    }
}

@Suite("Coffee Mode coverage honesty")
struct SupermuxCoffeeModeCoverageTests {
    @Test("Full AC coverage holds the deep-sleep layer")
    func fullCoverage() {
        let coverage = SupermuxCoffeeModeCoverage(
            isActive: true,
            powerSource: .ac,
            heldLayers: [.idleSystemSleep, .idleDisplaySleep, .systemSleep]
        )
        #expect(coverage.keepsSystemAwake)
        #expect(coverage.preventsDarkWakeSleep)
        #expect(!coverage.isDegraded)
        #expect(coverage.tooltip.contains("closing the lid still sleeps it"))
    }

    @Test("Battery coverage holds only the idle layers")
    func batteryCoverageWarns() {
        let coverage = SupermuxCoffeeModeCoverage(
            isActive: true,
            powerSource: .battery,
            heldLayers: [.idleSystemSleep, .idleDisplaySleep]
        )
        #expect(coverage.keepsSystemAwake)
        #expect(!coverage.preventsDarkWakeSleep)
        #expect(!coverage.isDegraded)
        #expect(coverage.tooltip.contains("closing the lid still sleeps it"))
    }

    @Test("Losing every assertion reports degraded, not working")
    func degradedWhenNothingHeld() {
        let coverage = SupermuxCoffeeModeCoverage(
            isActive: true,
            powerSource: .ac,
            heldLayers: []
        )
        #expect(!coverage.keepsSystemAwake)
        #expect(coverage.isDegraded)
        #expect(coverage.tooltip.contains("unavailable"))
    }

    @Test("Inactive coverage claims nothing")
    func offClaimsNothing() {
        #expect(!SupermuxCoffeeModeCoverage.off.keepsSystemAwake)
        #expect(!SupermuxCoffeeModeCoverage.off.preventsDarkWakeSleep)
        #expect(!SupermuxCoffeeModeCoverage.off.isDegraded)
    }
}

@Suite("Coffee Mode model")
@MainActor
struct SupermuxCoffeeModeModelTests {
    @Test("Starts off and holds no assertions")
    func startsOff() {
        let stub = StubKeepAwakeAssertions()
        let (model, _) = makeModel(stub)
        #expect(!model.isEnabled)
        #expect(stub.acquireCalls.isEmpty)
        #expect(model.coverage == .off)
    }

    @Test("Enabling acquires assertions and publishes coverage")
    func enablingAcquires() {
        let stub = StubKeepAwakeAssertions(powerSource: .ac)
        let (model, defaults) = makeModel(stub)
        model.toggle()

        #expect(model.isEnabled)
        #expect(stub.acquireCalls.count == 1)
        #expect(model.coverage.preventsDarkWakeSleep)
        #expect(defaults.bool(forKey: SupermuxCoffeeModeModel.enabledDefaultsKey))
    }

    @Test("Disabling releases every assertion and resets coverage")
    func disablingReleases() {
        let stub = StubKeepAwakeAssertions()
        let (model, defaults) = makeModel(stub)
        model.toggle()
        model.toggle()

        #expect(!model.isEnabled)
        #expect(stub.releaseAllCount == 1)
        #expect(stub.held.isEmpty)
        #expect(model.coverage == .off)
        #expect(!defaults.bool(forKey: SupermuxCoffeeModeModel.enabledDefaultsKey))
    }

    /// An agent left running overnight should survive an app restart with the
    /// Mac still kept awake.
    @Test("A persisted enabled flag re-acquires assertions at launch")
    func persistedFlagReacquires() {
        let stub = StubKeepAwakeAssertions()
        let (model, _) = makeModel(stub, persisted: true)
        #expect(model.isEnabled)
        #expect(stub.acquireCalls.count == 1)
        #expect(model.coverage.keepsSystemAwake)
    }

    /// Unplugging must drop the AC-only layer so coverage stops reporting
    /// protection the Mac no longer has.
    @Test("Unplugging drops the deep-sleep layer")
    func unpluggingDowngradesCoverage() {
        let stub = StubKeepAwakeAssertions(powerSource: .ac)
        let (model, _) = makeModel(stub)
        model.toggle()
        #expect(model.coverage.preventsDarkWakeSleep)

        stub.powerSource = .battery
        model.refreshForPowerSourceChange()

        #expect(!model.coverage.preventsDarkWakeSleep)
        #expect(model.coverage.keepsSystemAwake)
        #expect(stub.acquireCalls.last == [.idleSystemSleep, .idleDisplaySleep])
    }

    @Test("Plugging back in restores the deep-sleep layer")
    func pluggingInRestoresCoverage() {
        let stub = StubKeepAwakeAssertions(powerSource: .battery)
        let (model, _) = makeModel(stub)
        model.toggle()
        #expect(!model.coverage.preventsDarkWakeSleep)

        stub.powerSource = .ac
        model.refreshForPowerSourceChange()

        #expect(model.coverage.preventsDarkWakeSleep)
    }

    @Test("Power-source changes while disabled acquire nothing")
    func powerChangeWhileDisabledIsInert() {
        let stub = StubKeepAwakeAssertions()
        let (model, _) = makeModel(stub)
        model.refreshForPowerSourceChange()
        #expect(stub.acquireCalls.isEmpty)
        #expect(model.coverage == .off)
    }

    /// If macOS refuses the idle assertion, the mode must report degraded
    /// rather than let the user believe their agents are protected.
    @Test("A refused idle assertion surfaces as degraded")
    func refusedAssertionIsDegraded() {
        let stub = StubKeepAwakeAssertions(
            powerSource: .ac,
            refusedLayers: [.idleSystemSleep, .idleDisplaySleep, .systemSleep]
        )
        let (model, _) = makeModel(stub)
        model.toggle()

        #expect(model.isEnabled)
        #expect(model.coverage.isDegraded)
        #expect(!model.coverage.keepsSystemAwake)
    }

    @Test("Setting the same value twice does not re-acquire")
    func idempotentSetEnabled() {
        let stub = StubKeepAwakeAssertions()
        let (model, _) = makeModel(stub)
        model.setEnabled(true)
        model.setEnabled(true)
        #expect(stub.acquireCalls.count == 1)
    }

    /// The core honesty rule. No unprivileged assertion can prevent clamshell
    /// sleep — powerd's `setClamshellSleepState()` counts only assertions with
    /// `kAssertionLidStateModifier`, gated on the private
    /// `com.apple.private.iokit.assertonlidclose` entitlement. So every active
    /// tooltip must say the lid still sleeps the Mac, never imply otherwise.
    @Test("No active tooltip ever promises lid-close coverage", arguments: [
        SupermuxPowerSource.ac, .battery, .unknown,
    ])
    func tooltipNeverPromisesLidClose(powerSource: SupermuxPowerSource) {
        for layers in [
            Set(SupermuxKeepAwakeLayer.allCases),
            Set([SupermuxKeepAwakeLayer.idleSystemSleep, .idleDisplaySleep]),
            Set([SupermuxKeepAwakeLayer.idleSystemSleep]),
        ] {
            let tooltip = SupermuxCoffeeModeCoverage(
                isActive: true,
                powerSource: powerSource,
                heldLayers: layers
            ).tooltip
            #expect(tooltip.contains("closing the lid still sleeps it"))
            #expect(!tooltip.contains("including with the lid closed"))
        }
    }

    /// A refused IOPMAssertionRelease leaves the Mac awake. Going Off there
    /// would show an inactive icon over a live assertion with nothing left to
    /// release it — the exact dishonesty this design exists to avoid. Every
    /// signal must stay ON and agree: flag, persisted value, and coverage.
    @Test("A refused release leaves the mode fully on, not Off")
    func refusedReleaseStaysOn() {
        let stub = StubKeepAwakeAssertions(powerSource: .ac)
        stub.unreleasableLayers = [.idleSystemSleep]
        let (model, defaults) = makeModel(stub)
        model.toggle()
        model.toggle()

        #expect(model.isEnabled)
        #expect(defaults.bool(forKey: SupermuxCoffeeModeModel.enabledDefaultsKey))
        #expect(model.coverage.isActive)
        #expect(model.coverage.keepsSystemAwake)
    }

    /// Because `isEnabled` never flipped, the very next toggle is another
    /// release attempt rather than a redundant acquire.
    @Test("The next toggle retries a previously refused release")
    func toggleRetriesRefusedRelease() {
        let stub = StubKeepAwakeAssertions(powerSource: .ac)
        stub.unreleasableLayers = [.idleSystemSleep]
        let (model, _) = makeModel(stub)
        model.toggle()
        model.toggle()
        #expect(model.isEnabled)

        // powerd recovers; the next single toggle actually lets it go.
        stub.unreleasableLayers = []
        model.toggle()

        #expect(!model.isEnabled)
        #expect(model.coverage == .off)
        #expect(stub.held.isEmpty)
        #expect(stub.releaseAllCount == 2)
    }

    /// If IOPSNotificationCreateRunLoopSource fails, an unplug is undetectable.
    /// Claiming the AC-only layer would then report protection that silently
    /// goes inert the moment the user unplugs, with nothing to notice it.
    @Test("Unobservable power source withholds the AC-only layer")
    func unobservablePowerSourceWithholdsACLayer() {
        let stub = StubKeepAwakeAssertions(powerSource: .ac)
        let monitor = FailingPowerSourceMonitor()
        let suiteName = "supermux.coffee.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let model = SupermuxCoffeeModeModel(
            assertions: stub,
            defaults: defaults,
            powerSourceMonitor: monitor
        )
        model.toggle()

        #expect(model.coverage.keepsSystemAwake)
        #expect(!model.coverage.preventsDarkWakeSleep)
        #expect(stub.acquireCalls.last == [.idleSystemSleep, .idleDisplaySleep])
    }
}

/// A monitor whose run-loop source cannot be created, mirroring the documented
/// NULL return from `IOPSNotificationCreateRunLoopSource`.
@MainActor
private final class FailingPowerSourceMonitor: SupermuxPowerSourceObserving {
    func start(onChange: @escaping () -> Void) -> Bool { false }
    func stop() {}
}
