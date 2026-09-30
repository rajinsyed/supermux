import Foundation
import Testing

@testable import SupermuxKit

/// Ways remembering "the last Mac a worktree was created on" could fail
/// (written before the code):
/// 1. A project with no history reads some device.
/// 2. One project's choice leaks into another project.
/// 3. The choice does not survive a relaunch (a new store over the same
///    defaults reads nothing).
/// 4. The key drifts from the documented `supermux.newWorktree.lastDevice.v1`,
///    so a later build forgets every choice.
/// 5. A newer choice does not replace the older one.
/// 6. A corrupted stored value (not a dictionary, or non-string entries)
///    crashes or yields junk.
struct SupermuxWorktreeLastDeviceStoreTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "SupermuxWorktreeLastDeviceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func remembersPerProjectAcrossInstances() throws {
        let defaults = try makeDefaults()
        let first = UUID()
        let second = UUID()
        let store = SupermuxWorktreeLastDeviceStore(defaults: defaults)
        #expect(store.deviceKey(forProject: first) == nil)
        store.record(deviceKey: "device:aaaa@default", forProject: first)
        #expect(store.deviceKey(forProject: first) == "device:aaaa@default")
        #expect(store.deviceKey(forProject: second) == nil)
        #expect(SupermuxWorktreeLastDeviceStore(defaults: defaults).deviceKey(forProject: first) == "device:aaaa@default")
    }

    @Test func newerChoiceReplacesTheOlderOne() throws {
        let defaults = try makeDefaults()
        let project = UUID()
        let store = SupermuxWorktreeLastDeviceStore(defaults: defaults)
        store.record(deviceKey: "device:aaaa@default", forProject: project)
        store.record(deviceKey: SupermuxWorktreeDeviceEntry.thisMacKey, forProject: project)
        #expect(store.deviceKey(forProject: project) == SupermuxWorktreeDeviceEntry.thisMacKey)
    }

    @Test func usesTheDocumentedKey() throws {
        let defaults = try makeDefaults()
        #expect(SupermuxWorktreeLastDeviceStore.defaultsKey == "supermux.newWorktree.lastDevice.v1")
        let project = UUID()
        SupermuxWorktreeLastDeviceStore(defaults: defaults).record(deviceKey: "device:bbbb@x", forProject: project)
        let stored = defaults.dictionary(forKey: SupermuxWorktreeLastDeviceStore.defaultsKey) as? [String: String]
        #expect(stored?[project.uuidString] == "device:bbbb@x")
    }

    @Test func corruptedValuesReadAsNothingAndAreOverwritable() throws {
        let defaults = try makeDefaults()
        let project = UUID()
        defaults.set("not a dictionary", forKey: SupermuxWorktreeLastDeviceStore.defaultsKey)
        let store = SupermuxWorktreeLastDeviceStore(defaults: defaults)
        #expect(store.deviceKey(forProject: project) == nil)
        defaults.set([project.uuidString: 42], forKey: SupermuxWorktreeLastDeviceStore.defaultsKey)
        #expect(store.deviceKey(forProject: project) == nil)
        store.record(deviceKey: "device:cccc@default", forProject: project)
        #expect(store.deviceKey(forProject: project) == "device:cccc@default")
    }
}
