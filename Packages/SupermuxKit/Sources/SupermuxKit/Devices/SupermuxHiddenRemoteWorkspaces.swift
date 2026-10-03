public import Foundation

/// Remote workspaces the user chose to "Hide Here": auto-mirror never opens a
/// local mirror for them until they are unhidden.
///
/// Persisted as JSON in this app's own `UserDefaults` domain (so a tagged dev
/// build and the release app never share it). Entries are pruned by the
/// auto-mirror coordinator once their remote workspace is authoritatively
/// gone, so the set stays small without a capacity bound.
///
/// ```swift
/// hidden.hide(ref)                        // "Hide Here"
/// hidden.contains(ref)                    // auto-mirror skips it
/// hidden.unhide(machineID: nil)           // "Show Hidden Remote Workspaces"
/// ```
@MainActor
public final class SupermuxHiddenRemoteWorkspaces {
    /// The `UserDefaults` key holding the JSON array of refs.
    public static let defaultsKey = "supermux.devices.hiddenRemoteWorkspaces.v1"

    /// Every hidden remote workspace.
    public private(set) var refs: Set<SupermuxRemoteWorkspaceRef>

    private let defaults: UserDefaults
    private let key: String

    /// Loads the persisted set (a missing or corrupt value starts empty).
    public init(defaults: UserDefaults, key: String = SupermuxHiddenRemoteWorkspaces.defaultsKey) {
        self.defaults = defaults
        self.key = key
        refs = Self.load(defaults: defaults, key: key)
    }

    /// Whether auto-mirror must skip `ref`.
    public func contains(_ ref: SupermuxRemoteWorkspaceRef) -> Bool {
        refs.contains(ref)
    }

    /// Hides `ref` (idempotent).
    public func hide(_ ref: SupermuxRemoteWorkspaceRef) {
        guard refs.insert(ref).inserted else { return }
        save()
    }

    /// Unhides one ref. Returns whether it was hidden.
    @discardableResult
    public func unhide(_ ref: SupermuxRemoteWorkspaceRef) -> Bool {
        guard refs.remove(ref) != nil else { return false }
        save()
        return true
    }

    /// Unhides every ref of one device, or of every device when `machineID`
    /// is nil. Returns the refs it removed.
    @discardableResult
    public func unhide(machineID: String?) -> [SupermuxRemoteWorkspaceRef] {
        let removed = refs.filter { machineID == nil || $0.machineID == machineID }
        guard !removed.isEmpty else { return [] }
        refs.subtract(removed)
        save()
        return removed.sorted { $0.description < $1.description }
    }

    /// Drops refs whose remote workspace no longer exists.
    public func remove(_ gone: some Sequence<SupermuxRemoteWorkspaceRef>) {
        let before = refs.count
        refs.subtract(gone)
        guard refs.count != before else { return }
        save()
    }

    private func save() {
        let sorted = refs.sorted { $0.description < $1.description }
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(defaults: UserDefaults, key: String) -> Set<SupermuxRemoteWorkspaceRef> {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SupermuxRemoteWorkspaceRef].self, from: data) else { return [] }
        return Set(decoded)
    }
}
