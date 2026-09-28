import Foundation
import Testing
@testable import SupermuxKit

/// Ways the Devices defaults could fail:
/// Auto-mirror setting (`supermux.devices.autoMirror`):
/// 1. A fresh install reads OFF (the design says default ON).
/// 2. An explicit OFF does not persist (reads back as the default).
/// 3. The key string drifts from the documented `supermux.devices.autoMirror`.
/// One-time seeding of the Supermux release identity's Devices opt-ins:
/// 4. A key the user already set (true OR false) is overwritten.
/// 5. Unset keys are left unset.
/// 6. Seeding runs again on a later launch, re-enabling something the user removed.
/// 7. The marker is not written when every key was already set, so a later removal re-seeds.
/// 8. A different marker (a future seed version) is blocked by an older marker.
struct SupermuxDevicesSettingsTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "SupermuxDevicesSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func autoMirrorDefaultsOnAndPersistsExplicitChoices() throws {
        let defaults = try makeDefaults()
        #expect(SupermuxDevicesSettings.autoMirrorKey == "supermux.devices.autoMirror")
        let settings = SupermuxDevicesSettings(defaults: defaults)
        #expect(settings.autoMirror)
        settings.autoMirror = false
        #expect(SupermuxDevicesSettings(defaults: defaults).autoMirror == false)
        #expect(defaults.object(forKey: SupermuxDevicesSettings.autoMirrorKey) as? Bool == false)
        settings.autoMirror = true
        #expect(SupermuxDevicesSettings(defaults: defaults).autoMirror)
    }

    @Test func seedsOnlyUnsetKeys() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: "explicit.off")
        defaults.set(true, forKey: "explicit.on")
        let seeded = SupermuxDefaultsSeed.applyOnce(
            ["explicit.off": true, "explicit.on": true, "unset": true],
            marker: "seed.v1",
            defaults: defaults
        )
        #expect(seeded == ["unset"])
        #expect(defaults.object(forKey: "explicit.off") as? Bool == false)
        #expect(defaults.object(forKey: "explicit.on") as? Bool == true)
        #expect(defaults.object(forKey: "unset") as? Bool == true)
    }

    @Test func seedsOnlyOnce() throws {
        let defaults = try makeDefaults()
        SupermuxDefaultsSeed.applyOnce(["a": true], marker: "seed.v1", defaults: defaults)
        defaults.removeObject(forKey: "a")
        let second = SupermuxDefaultsSeed.applyOnce(["a": true], marker: "seed.v1", defaults: defaults)
        #expect(second.isEmpty)
        #expect(defaults.object(forKey: "a") == nil, "a user who removed the value is not re-seeded")
    }

    @Test func markerIsWrittenEvenWhenNothingNeededSeeding() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: "a")
        #expect(SupermuxDefaultsSeed.applyOnce(["a": true], marker: "seed.v1", defaults: defaults).isEmpty)
        defaults.removeObject(forKey: "a")
        #expect(SupermuxDefaultsSeed.applyOnce(["a": true], marker: "seed.v1", defaults: defaults).isEmpty)
        #expect(defaults.object(forKey: "a") == nil)
    }

    @Test func aNewMarkerSeedsIndependently() throws {
        let defaults = try makeDefaults()
        SupermuxDefaultsSeed.applyOnce(["a": true], marker: "seed.v1", defaults: defaults)
        let v2 = SupermuxDefaultsSeed.applyOnce(["a": true, "b": true], marker: "seed.v2", defaults: defaults)
        #expect(v2 == ["b"])
    }
}
