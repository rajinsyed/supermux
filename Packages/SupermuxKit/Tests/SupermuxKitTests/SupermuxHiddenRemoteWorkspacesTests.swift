import Foundation
import Testing
@testable import SupermuxKit

/// Ways the "Hide Here" set could fail (written before the code):
/// 1. A hidden workspace comes back after an app restart (not persisted).
/// 2. The same remote workspace spelled in another case is not recognized as hidden.
/// 3. Unhiding one Mac's workspaces also unhides another Mac's.
/// 4. Unhide-all leaves entries behind, or reports the wrong refs.
/// 5. A corrupt stored value crashes or poisons the set (instead of starting empty).
/// 6. The defaults key drifts from the documented `supermux.devices.hiddenRemoteWorkspaces.v1`.
/// 7. Removing refs that are not hidden rewrites or corrupts the store.
@MainActor
struct SupermuxHiddenRemoteWorkspacesTests {
    private let machine = "device:5E1F10B0-0000-4000-8000-000000000001@dev"
    private let other = "device:AAAAAAAA-0000-4000-8000-000000000002@dev"

    private func makeDefaults() throws -> UserDefaults {
        let suite = "SupermuxHiddenRemoteWorkspacesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func ref(_ id: String, on machine: String? = nil) -> SupermuxRemoteWorkspaceRef {
        SupermuxRemoteWorkspaceRef(machineID: machine ?? self.machine, workspaceID: id)
    }

    @Test func hiddenRefsSurviveARestart() throws {
        let defaults = try makeDefaults()
        #expect(SupermuxHiddenRemoteWorkspaces.defaultsKey == "supermux.devices.hiddenRemoteWorkspaces.v1")
        let store = SupermuxHiddenRemoteWorkspaces(defaults: defaults)
        store.hide(ref("A"))
        store.hide(ref("A"))
        let reloaded = SupermuxHiddenRemoteWorkspaces(defaults: defaults)
        #expect(reloaded.refs == [ref("A")])
        #expect(reloaded.contains(ref("A")))
    }

    @Test func uuidSpellingsMatch() throws {
        let store = SupermuxHiddenRemoteWorkspaces(defaults: try makeDefaults())
        let id = "0B3A6F1E-0000-4000-8000-00000000000A"
        store.hide(ref(id.lowercased()))
        #expect(store.contains(ref(id)))
    }

    @Test func unhidingOneMacLeavesTheOthers() throws {
        let defaults = try makeDefaults()
        let store = SupermuxHiddenRemoteWorkspaces(defaults: defaults)
        store.hide(ref("A"))
        store.hide(ref("B", on: other))
        let removed = store.unhide(machineID: machine)
        #expect(removed == [ref("A")])
        #expect(SupermuxHiddenRemoteWorkspaces(defaults: defaults).refs == [ref("B", on: other)])
    }

    @Test func unhideAllEmptiesTheSet() throws {
        let defaults = try makeDefaults()
        let store = SupermuxHiddenRemoteWorkspaces(defaults: defaults)
        store.hide(ref("A"))
        store.hide(ref("B", on: other))
        let removed = store.unhide(machineID: nil)
        #expect(Set(removed) == [ref("A"), ref("B", on: other)])
        #expect(SupermuxHiddenRemoteWorkspaces(defaults: defaults).refs.isEmpty)
    }

    @Test func unhidingOneRefOnly() throws {
        let store = SupermuxHiddenRemoteWorkspaces(defaults: try makeDefaults())
        store.hide(ref("A"))
        store.hide(ref("B"))
        #expect(store.unhide(ref("A")))
        #expect(!store.unhide(ref("A")), "a second unhide reports nothing removed")
        #expect(store.refs == [ref("B")])
    }

    @Test func corruptStorageStartsEmpty() throws {
        let defaults = try makeDefaults()
        defaults.set(Data("not json".utf8), forKey: SupermuxHiddenRemoteWorkspaces.defaultsKey)
        let store = SupermuxHiddenRemoteWorkspaces(defaults: defaults)
        #expect(store.refs.isEmpty)
        store.hide(ref("A"))
        #expect(SupermuxHiddenRemoteWorkspaces(defaults: defaults).refs == [ref("A")])
    }

    @Test func removingUnknownRefsIsANoOp() throws {
        let defaults = try makeDefaults()
        let store = SupermuxHiddenRemoteWorkspaces(defaults: defaults)
        store.hide(ref("A"))
        store.remove([ref("zzz")])
        #expect(SupermuxHiddenRemoteWorkspaces(defaults: defaults).refs == [ref("A")])
        store.remove([ref("A")])
        #expect(SupermuxHiddenRemoteWorkspaces(defaults: defaults).refs.isEmpty)
    }
}
