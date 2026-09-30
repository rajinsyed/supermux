import Foundation
import Testing

@testable import SupermuxKit

/// Ways remembering "the last Mac a worktree was created on" could fail
/// (written before the code):
/// 1. Nothing recorded yet reads some device.
/// 2. A choice made in one project is not read for another project (the
///    memory is one choice for every project).
/// 3. The choice does not survive a relaunch (a new store over the same
///    defaults reads nothing).
/// 4. The key drifts from the documented `supermux.newWorktree.lastDevice.v2`
///    (or stops being one plain string), so a later build forgets the choice.
/// 5. A newer choice does not replace the older one.
/// 6. A corrupted stored value (not a string), or the old per-project map of
///    `supermux.newWorktree.lastDevice.v1`, crashes or yields junk.
struct SupermuxWorktreeLastDeviceStoreTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "SupermuxWorktreeLastDeviceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func remembersOneChoiceAcrossInstances() throws {
        let defaults = try makeDefaults()
        let store = SupermuxWorktreeLastDeviceStore(defaults: defaults)
        #expect(store.deviceKey() == nil)
        store.record(deviceKey: "device:aaaa@default")
        #expect(store.deviceKey() == "device:aaaa@default")
        #expect(SupermuxWorktreeLastDeviceStore(defaults: defaults).deviceKey() == "device:aaaa@default")
    }

    @Test func aChoiceMadeInOneProjectIsReadForAnyProject() throws {
        let defaults = try makeDefaults()
        let studio = SupermuxProjectDevice(machineID: "device:aaaa@default", name: "Studio", isOnline: true)
        // A worktree created on Studio from one project's sheet…
        SupermuxWorktreeLastDeviceStore(defaults: defaults).record(deviceKey: studio.machineID)
        // …makes Studio the default of another project's sheet.
        let other = SupermuxUnifiedProject(
            id: UUID(), name: "other", colorHex: nil, iconSymbol: nil, gitRemoteIdentity: nil,
            locations: [
                SupermuxProjectLocation(place: .thisMac, projectID: UUID(), rootPath: "/src/other"),
                SupermuxProjectLocation(place: .device(studio), projectID: UUID(), rootPath: "/src/other"),
            ]
        )
        let entries = SupermuxWorktreeDevicePlanner.entries(for: other, availability: [:], setUpTargets: [])
        let initial = SupermuxWorktreeDevicePlanner.defaultEntryID(
            in: entries,
            preferredDeviceKey: nil,
            lastUsedDeviceKey: SupermuxWorktreeLastDeviceStore(defaults: defaults).deviceKey()
        )
        #expect(initial == studio.machineID)
    }

    @Test func newerChoiceReplacesTheOlderOne() throws {
        let defaults = try makeDefaults()
        let store = SupermuxWorktreeLastDeviceStore(defaults: defaults)
        store.record(deviceKey: "device:aaaa@default")
        store.record(deviceKey: SupermuxWorktreeDeviceEntry.thisMacKey)
        #expect(store.deviceKey() == SupermuxWorktreeDeviceEntry.thisMacKey)
    }

    @Test func usesTheDocumentedKey() throws {
        let defaults = try makeDefaults()
        #expect(SupermuxWorktreeLastDeviceStore.defaultsKey == "supermux.newWorktree.lastDevice.v2")
        SupermuxWorktreeLastDeviceStore(defaults: defaults).record(deviceKey: "device:bbbb@x")
        #expect(defaults.object(forKey: SupermuxWorktreeLastDeviceStore.defaultsKey) as? String == "device:bbbb@x")
    }

    @Test func corruptedOrOldValuesReadAsNothingAndAreOverwritable() throws {
        let defaults = try makeDefaults()
        let store = SupermuxWorktreeLastDeviceStore(defaults: defaults)
        defaults.set([UUID().uuidString: "device:aaaa@default"], forKey: "supermux.newWorktree.lastDevice.v1")
        #expect(store.deviceKey() == nil)
        defaults.set(42, forKey: SupermuxWorktreeLastDeviceStore.defaultsKey)
        #expect(store.deviceKey() == nil)
        defaults.set(["device:aaaa@default"], forKey: SupermuxWorktreeLastDeviceStore.defaultsKey)
        #expect(store.deviceKey() == nil)
        store.record(deviceKey: "device:cccc@default")
        #expect(store.deviceKey() == "device:cccc@default")
    }
}
