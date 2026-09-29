public import Foundation

/// Persists which local workspace mirrors which remote workspace, so a mirror
/// keeps its identity across app restarts even while its panes are restore
/// placeholders, or have none.
///
/// Keyed by the local workspace's restart-stable id (`Workspace.stableId`,
/// restored by session restore together with `Workspace.id`); the last-known
/// `Workspace.id` rides along as a fallback key. One remote workspace binds to
/// at most one local workspace: binding it again moves it.
///
/// Stored as JSON in the app's own `UserDefaults` domain, so concurrently
/// running builds (stable, tagged dev builds) never share or clobber it.
/// Bounded: past `capacity` the least recently bound entries are evicted,
/// and ``prune(keepingStableIDs:)`` drops bindings of closed workspaces.
///
/// ```swift
/// store.bind(stableID: workspace.stableId, workspaceID: workspace.id, to: ref)
/// store.ref(forStableID: workspace.stableId)   // after a restart too
/// ```
@MainActor
public final class SupermuxDeviceBindingStore {
    /// One persisted binding.
    public struct Binding: Codable, Equatable, Sendable {
        /// The remote workspace the local workspace mirrors.
        public let ref: SupermuxRemoteWorkspaceRef
        /// The local `Workspace.id` when the binding was last written.
        public let workspaceID: UUID
        /// When the binding was last written (eviction order).
        public let boundAt: Date
        /// The remote customization last applied to the mirror (nil until the
        /// first status projection, or for bindings stored before it existed).
        public var appliedCustomization: SupermuxMirrorCustomization?

        private enum CodingKeys: String, CodingKey {
            case ref
            case workspaceID = "workspace_id"
            case boundAt = "bound_at"
            case appliedCustomization = "applied_customization"
        }
    }

    /// The `UserDefaults` key holding the JSON map.
    public static let defaultsKey = "supermux.devices.mirrorBindings.v1"
    /// The default maximum number of bindings kept.
    public static let defaultCapacity = 512

    /// Every binding, keyed by the local workspace's stable id.
    public private(set) var bindings: [UUID: Binding] = [:]

    private var stableIDsByRef: [SupermuxRemoteWorkspaceRef: UUID] = [:]
    private let defaults: UserDefaults
    private let key: String
    private let capacity: Int
    private let now: () -> Date

    /// Loads the persisted map (a missing or corrupt value starts empty).
    /// - Parameters:
    ///   - defaults: The defaults domain to persist into.
    ///   - key: The defaults key.
    ///   - capacity: Maximum bindings kept; older ones are evicted first.
    ///   - now: The clock used to order evictions.
    public init(
        defaults: UserDefaults,
        key: String = SupermuxDeviceBindingStore.defaultsKey,
        capacity: Int = SupermuxDeviceBindingStore.defaultCapacity,
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.key = key
        self.capacity = max(1, capacity)
        self.now = now
        bindings = Self.load(defaults: defaults, key: key)
        rebuildReverseIndex()
    }

    /// Binds a local workspace to a remote workspace, replacing any previous
    /// binding of either side. The applied customization carries over only
    /// when the same pair is bound again.
    public func bind(stableID: UUID, workspaceID: UUID, to ref: SupermuxRemoteWorkspaceRef) {
        if let previousOwner = stableIDsByRef[ref], previousOwner != stableID {
            bindings[previousOwner] = nil
        }
        let previous = bindings[stableID]
        bindings[stableID] = Binding(
            ref: ref,
            workspaceID: workspaceID,
            boundAt: now(),
            appliedCustomization: previous?.ref == ref ? previous?.appliedCustomization : nil
        )
        evictOverflow()
        rebuildReverseIndex()
        save()
    }

    /// Removes the binding of a local workspace.
    public func unbind(stableID: UUID) {
        guard bindings.removeValue(forKey: stableID) != nil else { return }
        rebuildReverseIndex()
        save()
    }

    /// Removes the binding of a remote workspace.
    public func unbind(ref: SupermuxRemoteWorkspaceRef) {
        guard let stableID = stableIDsByRef[ref] else { return }
        unbind(stableID: stableID)
    }

    /// The remote workspace a local workspace mirrors.
    public func ref(forStableID stableID: UUID) -> SupermuxRemoteWorkspaceRef? {
        bindings[stableID]?.ref
    }

    /// The remote workspace bound under a last-known local `Workspace.id`.
    public func ref(forWorkspaceID workspaceID: UUID) -> SupermuxRemoteWorkspaceRef? {
        bindings.values.first { $0.workspaceID == workspaceID }?.ref
    }

    /// The local workspace's stable id bound to a remote workspace.
    public func stableID(for ref: SupermuxRemoteWorkspaceRef) -> UUID? {
        stableIDsByRef[ref]
    }

    /// The remote customization last applied to the mirror bound under `stableID`.
    public func appliedCustomization(forStableID stableID: UUID) -> SupermuxMirrorCustomization? {
        bindings[stableID]?.appliedCustomization
    }

    /// Remembers the remote customization just applied to the mirror bound
    /// under `stableID` (ignored when nothing is bound there).
    public func recordAppliedCustomization(_ customization: SupermuxMirrorCustomization, forStableID stableID: UUID) {
        guard var binding = bindings[stableID], binding.appliedCustomization != customization else { return }
        binding.appliedCustomization = customization
        bindings[stableID] = binding
        save()
    }

    /// Drops every binding whose local workspace is gone. Call only once the
    /// session restore has finished, or restored mirrors lose their binding.
    public func prune(keepingStableIDs live: Set<UUID>) {
        let before = bindings.count
        bindings = bindings.filter { live.contains($0.key) }
        guard bindings.count != before else { return }
        rebuildReverseIndex()
        save()
    }

    private func evictOverflow() {
        guard bindings.count > capacity else { return }
        let overflow = bindings.count - capacity
        let oldest = bindings.sorted { $0.value.boundAt < $1.value.boundAt }.prefix(overflow)
        for (stableID, _) in oldest { bindings[stableID] = nil }
    }

    private func rebuildReverseIndex() {
        stableIDsByRef = Dictionary(
            bindings.map { ($0.value.ref, $0.key) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func save() {
        let encoded = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(defaults: UserDefaults, key: String) -> [UUID: Binding] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Binding].self, from: data) else { return [:] }
        var bindings: [UUID: Binding] = [:]
        for (rawID, binding) in decoded {
            guard let stableID = UUID(uuidString: rawID) else { continue }
            bindings[stableID] = binding
        }
        return bindings
    }
}
