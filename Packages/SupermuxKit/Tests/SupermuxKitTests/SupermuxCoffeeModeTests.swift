import Foundation
import Testing

@testable import SupermuxKit

@MainActor
private final class StubKeepAwakeAssertion: SupermuxKeepAwakeAsserting {
    var acquireSucceeds = true
    var releaseSucceeds = true

    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    private(set) var isHeld = false

    func acquire() -> Bool {
        acquireCount += 1
        guard acquireSucceeds else {
            isHeld = false
            return false
        }
        isHeld = true
        return true
    }

    func release() -> Bool {
        releaseCount += 1
        guard releaseSucceeds else {
            return false
        }
        isHeld = false
        return true
    }
}

@MainActor
private func makeModel(
    assertion: StubKeepAwakeAssertion = StubKeepAwakeAssertion(),
    persisted: Bool = false
) -> (SupermuxCoffeeModeModel, StubKeepAwakeAssertion, UserDefaults) {
    let defaults = UserDefaults(suiteName: "supermux.coffee.tests.\(UUID().uuidString)")!
    defaults.set(persisted, forKey: SupermuxCoffeeModeModel.enabledDefaultsKey)
    return (
        SupermuxCoffeeModeModel(assertion: assertion, defaults: defaults),
        assertion,
        defaults
    )
}

@Suite("Coffee Mode coverage")
struct SupermuxCoffeeModeCoverageTests {
    @Test("Inactive coverage claims nothing")
    func offClaimsNothing() {
        #expect(!SupermuxCoffeeModeCoverage.off.isActive)
        #expect(!SupermuxCoffeeModeCoverage.off.keepsSystemAwake)
        #expect(!SupermuxCoffeeModeCoverage.off.isDegraded)
    }

    @Test("Active coverage says the Mac stays awake only while open")
    func activeCoverageStatesLidCaveat() {
        let coverage = SupermuxCoffeeModeCoverage(
            isActive: true,
            keepsSystemAwake: true
        )

        #expect(!coverage.isDegraded)
        #expect(coverage.tooltip.contains("Mac stays awake while open"))
        #expect(coverage.tooltip.contains("closing the lid still sleeps it"))
    }

    @Test("A refused assertion reports unavailable")
    func refusedAssertionIsDegraded() {
        let coverage = SupermuxCoffeeModeCoverage(
            isActive: true,
            keepsSystemAwake: false
        )

        #expect(coverage.isDegraded)
        #expect(coverage.tooltip.contains("unavailable"))
    }
}

@Suite("Coffee Mode model")
@MainActor
struct SupermuxCoffeeModeModelTests {
    @Test("Starts off without acquiring an assertion")
    func startsOff() {
        let (model, assertion, _) = makeModel()

        #expect(!model.isEnabled)
        #expect(model.coverage == .off)
        #expect(assertion.acquireCount == 0)
    }

    @Test("Enabling acquires one assertion and persists the state")
    func enablingAcquires() {
        let (model, assertion, defaults) = makeModel()
        model.toggle()

        #expect(model.isEnabled)
        #expect(model.coverage.keepsSystemAwake)
        #expect(assertion.acquireCount == 1)
        #expect(assertion.isHeld)
        #expect(defaults.bool(forKey: SupermuxCoffeeModeModel.enabledDefaultsKey))
    }

    @Test("A refused acquire stays visibly enabled but degraded")
    func refusedAcquireIsDegraded() {
        let assertion = StubKeepAwakeAssertion()
        assertion.acquireSucceeds = false
        let (model, _, defaults) = makeModel(assertion: assertion)
        model.toggle()

        #expect(model.isEnabled)
        #expect(model.coverage.isDegraded)
        #expect(!model.coverage.keepsSystemAwake)
        #expect(defaults.bool(forKey: SupermuxCoffeeModeModel.enabledDefaultsKey))
    }

    @Test("Disabling releases the assertion and clears persistence")
    func disablingReleases() {
        let (model, assertion, defaults) = makeModel()
        model.toggle()
        model.toggle()

        #expect(!model.isEnabled)
        #expect(model.coverage == .off)
        #expect(assertion.releaseCount == 1)
        #expect(!assertion.isHeld)
        #expect(!defaults.bool(forKey: SupermuxCoffeeModeModel.enabledDefaultsKey))
    }

    @Test("A refused release leaves every signal on")
    func refusedReleaseStaysOn() {
        let assertion = StubKeepAwakeAssertion()
        assertion.releaseSucceeds = false
        let (model, _, defaults) = makeModel(assertion: assertion)
        model.toggle()
        model.toggle()

        #expect(model.isEnabled)
        #expect(model.coverage.keepsSystemAwake)
        #expect(assertion.isHeld)
        #expect(defaults.bool(forKey: SupermuxCoffeeModeModel.enabledDefaultsKey))
    }

    @Test("The next toggle retries a previously refused release")
    func retryRefusedRelease() {
        let assertion = StubKeepAwakeAssertion()
        assertion.releaseSucceeds = false
        let (model, _, _) = makeModel(assertion: assertion)
        model.toggle()
        model.toggle()
        #expect(model.isEnabled)

        assertion.releaseSucceeds = true
        model.toggle()

        #expect(!model.isEnabled)
        #expect(model.coverage == .off)
        #expect(assertion.releaseCount == 2)
    }

    @Test("A persisted enabled state re-acquires at construction")
    func persistedStateReacquires() {
        let (model, assertion, _) = makeModel(persisted: true)

        #expect(model.isEnabled)
        #expect(model.coverage.keepsSystemAwake)
        #expect(assertion.acquireCount == 1)
    }

    @Test("Setting the current state is idempotent")
    func idempotentSetEnabled() {
        let (model, assertion, _) = makeModel()
        model.setEnabled(false)
        #expect(assertion.releaseCount == 0)

        model.setEnabled(true)
        model.setEnabled(true)
        #expect(assertion.acquireCount == 1)
    }
}
