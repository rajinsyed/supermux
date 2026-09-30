import Foundation
import Testing
@testable import SupermuxKit

/// Ways the local-mirror <-> remote-workspace binding store could fail:
/// 1. A binding does not survive an app restart (a fresh store on the same defaults loses it).
/// 2. The same remote workspace spelled with a lowercase vs uppercase UUID is treated as two refs,
///    so a mirror is never found again (records use uppercase, some paths lowercase).
/// 3. Decoding a persisted ref skips canonicalization, so an old lowercase entry never matches.
/// 4. One remote workspace ends up bound to two local workspaces (duplicate mirrors after restore).
/// 5. Rebinding a local workspace to another ref leaves the old ref resolvable.
/// 6. Unbinding by stable id or by ref leaves a dangling reverse entry.
/// 7. The last-known local workspace id is not updated on rebind, so the id fallback goes stale.
/// 8. Corrupt persisted data crashes or wedges the store instead of starting empty.
/// 9. The map grows without bound (closed mirrors never unbound) — oldest entries must be evicted.
/// 10. Pruning to the live stable ids drops a live binding or keeps a dead one.
///
/// The remote customization (color / description / pin) last applied to a mirror:
/// 11. It does not survive a restart, so every relaunch treats a restored mirror as
///     first sight and overwrites the user's local edits with the remote values.
/// 12. It follows the ref to another local workspace (that new mirror would never
///     get the remote values), or survives a rebind of the workspace to another ref.
/// 13. Bindings persisted before it existed no longer load (every mirror loses its identity).
/// 14. Recording it for an unbound workspace creates a binding out of nothing.
@MainActor
struct SupermuxDeviceBindingStoreTests {
    private let machine = "device:0f7c2c7e-1d51-4d0e-9d7c-2c9b2a4b7e11@default"

    private func makeDefaults() throws -> UserDefaults {
        let suite = "SupermuxDeviceBindingStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func ref(_ workspace: String) -> SupermuxRemoteWorkspaceRef {
        SupermuxRemoteWorkspaceRef(machineID: machine, workspaceID: workspace)
    }

    @Test func bindingSurvivesARestart() throws {
        let defaults = try makeDefaults()
        let stable = UUID()
        let local = UUID()
        let remote = ref(UUID().uuidString)
        SupermuxDeviceBindingStore(defaults: defaults).bind(stableID: stable, workspaceID: local, to: remote)

        let restarted = SupermuxDeviceBindingStore(defaults: defaults)
        #expect(restarted.ref(forStableID: stable) == remote)
        #expect(restarted.ref(forWorkspaceID: local) == remote)
        #expect(restarted.stableID(for: remote) == stable)
    }

    @Test func workspaceIDCaseDoesNotSplitARef() {
        let id = UUID()
        let upper = ref(id.uuidString.uppercased())
        let lower = ref(id.uuidString.lowercased())
        #expect(upper == lower)
        #expect(upper.hashValue == lower.hashValue)
        #expect(lower.workspaceID == id.uuidString)
        #expect(ref("  \(id.uuidString.lowercased()) ").workspaceID == id.uuidString)
        #expect(ref("ws_named").workspaceID == "ws_named", "non-UUID ids are kept verbatim")
    }

    @Test func decodingCanonicalizesPersistedRefs() throws {
        let id = UUID()
        let json = #"{"machine_id":"\#(machine)","workspace_id":"\#(id.uuidString.lowercased())"}"#
        let decoded = try JSONDecoder().decode(SupermuxRemoteWorkspaceRef.self, from: Data(json.utf8))
        #expect(decoded == ref(id.uuidString))
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: String]
        #expect(reencoded?["machine_id"] == machine)
        #expect(reencoded?["workspace_id"] == id.uuidString)
    }

    @Test func aRemoteWorkspaceBindsToOneLocalWorkspace() throws {
        let store = SupermuxDeviceBindingStore(defaults: try makeDefaults())
        let remote = ref(UUID().uuidString)
        let first = UUID()
        let second = UUID()
        store.bind(stableID: first, workspaceID: UUID(), to: remote)
        store.bind(stableID: second, workspaceID: UUID(), to: remote)
        #expect(store.ref(forStableID: first) == nil, "the earlier mirror loses the ref")
        #expect(store.ref(forStableID: second) == remote)
        #expect(store.stableID(for: remote) == second)
        #expect(store.bindings.count == 1)
    }

    @Test func rebindingMovesTheLocalWorkspaceToTheNewRef() throws {
        let store = SupermuxDeviceBindingStore(defaults: try makeDefaults())
        let stable = UUID()
        let old = ref(UUID().uuidString)
        let new = ref(UUID().uuidString)
        let newLocalID = UUID()
        store.bind(stableID: stable, workspaceID: UUID(), to: old)
        store.bind(stableID: stable, workspaceID: newLocalID, to: new)
        #expect(store.ref(forStableID: stable) == new)
        #expect(store.stableID(for: old) == nil)
        #expect(store.ref(forWorkspaceID: newLocalID) == new, "the last-known local id follows the rebind")
    }

    @Test func unbindingRemovesBothDirections() throws {
        let defaults = try makeDefaults()
        let store = SupermuxDeviceBindingStore(defaults: defaults)
        let a = (stable: UUID(), local: UUID(), ref: ref(UUID().uuidString))
        let b = (stable: UUID(), local: UUID(), ref: ref(UUID().uuidString))
        store.bind(stableID: a.stable, workspaceID: a.local, to: a.ref)
        store.bind(stableID: b.stable, workspaceID: b.local, to: b.ref)

        store.unbind(stableID: a.stable)
        #expect(store.ref(forStableID: a.stable) == nil)
        #expect(store.stableID(for: a.ref) == nil)
        #expect(store.ref(forWorkspaceID: a.local) == nil)

        store.unbind(ref: b.ref)
        #expect(store.ref(forStableID: b.stable) == nil)
        #expect(store.bindings.isEmpty)
        #expect(SupermuxDeviceBindingStore(defaults: defaults).bindings.isEmpty, "unbinds persist")
    }

    @Test func corruptPersistedDataStartsEmptyAndRecovers() throws {
        let defaults = try makeDefaults()
        defaults.set(Data("not json".utf8), forKey: SupermuxDeviceBindingStore.defaultsKey)
        let store = SupermuxDeviceBindingStore(defaults: defaults)
        #expect(store.bindings.isEmpty)
        let remote = ref(UUID().uuidString)
        let stable = UUID()
        store.bind(stableID: stable, workspaceID: UUID(), to: remote)
        #expect(SupermuxDeviceBindingStore(defaults: defaults).ref(forStableID: stable) == remote)

        defaults.set("a string, not data", forKey: SupermuxDeviceBindingStore.defaultsKey)
        #expect(SupermuxDeviceBindingStore(defaults: defaults).bindings.isEmpty)
    }

    @Test func capacityEvictsTheOldestBindings() throws {
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = SupermuxDeviceBindingStore(
            defaults: try makeDefaults(),
            capacity: 3,
            now: { clock }
        )
        var stables: [UUID] = []
        for _ in 0..<5 {
            clock.addTimeInterval(1)
            let stable = UUID()
            stables.append(stable)
            store.bind(stableID: stable, workspaceID: UUID(), to: ref(UUID().uuidString))
        }
        #expect(store.bindings.count == 3)
        #expect(store.ref(forStableID: stables[0]) == nil)
        #expect(store.ref(forStableID: stables[1]) == nil)
        #expect(store.ref(forStableID: stables[4]) != nil)
    }

    @Test func pruneKeepsExactlyTheLiveStableIDs() throws {
        let store = SupermuxDeviceBindingStore(defaults: try makeDefaults())
        let live = UUID()
        let dead = UUID()
        store.bind(stableID: live, workspaceID: UUID(), to: ref(UUID().uuidString))
        store.bind(stableID: dead, workspaceID: UUID(), to: ref(UUID().uuidString))
        store.prune(keepingStableIDs: [live, UUID()])
        #expect(store.ref(forStableID: live) != nil)
        #expect(store.ref(forStableID: dead) == nil)
        #expect(store.bindings.count == 1)
    }

    // MARK: - Applied remote customization

    private let customization = SupermuxMirrorCustomization(colorHex: "#34C759", description: "remote", isPinned: true)

    @Test func appliedCustomizationSurvivesARestart() throws {
        let defaults = try makeDefaults()
        let stable = UUID()
        let store = SupermuxDeviceBindingStore(defaults: defaults)
        store.bind(stableID: stable, workspaceID: UUID(), to: ref(UUID().uuidString))
        store.recordAppliedCustomization(customization, forStableID: stable)
        #expect(store.appliedCustomization(forStableID: stable) == customization)
        #expect(SupermuxDeviceBindingStore(defaults: defaults).appliedCustomization(forStableID: stable) == customization)
    }

    @Test func appliedCustomizationBelongsToOneBinding() throws {
        let store = SupermuxDeviceBindingStore(defaults: try makeDefaults())
        let remote = ref(UUID().uuidString)
        let first = UUID()
        store.bind(stableID: first, workspaceID: UUID(), to: remote)
        store.recordAppliedCustomization(customization, forStableID: first)
        store.bind(stableID: first, workspaceID: UUID(), to: remote)
        #expect(store.appliedCustomization(forStableID: first) == customization, "binding the same pair again keeps it")

        let second = UUID()
        store.bind(stableID: second, workspaceID: UUID(), to: remote)
        #expect(store.appliedCustomization(forStableID: second) == nil, "a new mirror of the ref starts from first sight")

        store.recordAppliedCustomization(customization, forStableID: second)
        store.bind(stableID: second, workspaceID: UUID(), to: ref(UUID().uuidString))
        #expect(store.appliedCustomization(forStableID: second) == nil, "a rebind to another ref starts from first sight")
    }

    @Test func bindingsStoredBeforeCustomizationStillLoad() throws {
        let defaults = try makeDefaults()
        let stable = UUID()
        let remote = ref(UUID().uuidString)
        let binding: [String: Any] = [
            "ref": ["machine_id": machine, "workspace_id": remote.workspaceID],
            "workspace_id": UUID().uuidString,
            "bound_at": 1000,
        ]
        let data = try JSONSerialization.data(withJSONObject: [stable.uuidString: binding])
        defaults.set(data, forKey: SupermuxDeviceBindingStore.defaultsKey)
        let store = SupermuxDeviceBindingStore(defaults: defaults)
        #expect(store.ref(forStableID: stable) == remote)
        #expect(store.appliedCustomization(forStableID: stable) == nil)
    }

    @Test func recordingForAnUnboundWorkspaceIsIgnored() throws {
        let defaults = try makeDefaults()
        let store = SupermuxDeviceBindingStore(defaults: defaults)
        let stable = UUID()
        store.recordAppliedCustomization(customization, forStableID: stable)
        #expect(store.bindings.isEmpty)
        #expect(store.appliedCustomization(forStableID: stable) == nil)
        #expect(SupermuxDeviceBindingStore(defaults: defaults).bindings.isEmpty)
    }
}
