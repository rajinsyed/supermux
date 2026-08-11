import Foundation
import Testing

@testable import CMUXMobileCore

@Suite("Terminal scroll speed preference")
struct MobileTerminalScrollSpeedPreferenceTests {
    @Test("resolves the default when nothing is stored")
    func resolvesDefault() throws {
        let suiteName = "MobileTerminalScrollSpeedPreferenceTests.default"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        #expect(MobileTerminalScrollSpeedPreference.resolve(from: defaults) == 1.0)
    }

    @Test("clamps stored values to the supported range")
    func clampsStoredValues() throws {
        let suiteName = "MobileTerminalScrollSpeedPreferenceTests.clamp"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        defaults.set(0.5, forKey: MobileTerminalScrollSpeedPreference.defaultsKey)
        #expect(MobileTerminalScrollSpeedPreference.resolve(from: defaults) == 0.5)

        defaults.set(50.0, forKey: MobileTerminalScrollSpeedPreference.defaultsKey)
        #expect(MobileTerminalScrollSpeedPreference.resolve(from: defaults) == 1.5)

        defaults.set(-3.0, forKey: MobileTerminalScrollSpeedPreference.defaultsKey)
        #expect(MobileTerminalScrollSpeedPreference.resolve(from: defaults) == 0.25)
    }

    @Test("non-finite values fall back to the default")
    func nonFiniteFallsBack() {
        #expect(MobileTerminalScrollSpeedPreference.clamped(.nan) == 1.0)
        #expect(MobileTerminalScrollSpeedPreference.clamped(.infinity) == 1.0)
    }
}
