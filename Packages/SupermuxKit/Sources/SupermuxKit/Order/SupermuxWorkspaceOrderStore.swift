public import Foundation
internal import SupermuxMobileCore

/// Persists the order key of every workspace this Mac owns, so the shared
/// order survives restarts and duplicate reopens.
///
/// Keyed by the workspace's restart-stable id (`Workspace.stableId`), which
/// session restore keeps even when a reopen mints a new `Workspace.id`.
/// Only the owner Mac writes a workspace's key; mirrors are never stored.
///
/// Stored as JSON in the app's own `UserDefaults` domain, so builds that run
/// side by side (stable, tagged dev builds) never share keys: each is its own
/// owner. Every change is written at once. A key that is not
/// ``SupermuxOrderKey/isValid(_:)`` is never stored or loaded. Call
/// ``prune(keepingStableIDs:)`` once the session restore has finished, and
/// again whenever ``isOverCapacity`` holds.
///
/// ```swift
/// let store = SupermuxWorkspaceOrderStore(defaults: .standard)   // at the composition root
/// store.setKeys([workspace.stableId: "a0V"])
/// store.key(forStableID: workspace.stableId)   // "a0V", after a restart too
/// ```
@MainActor
public final class SupermuxWorkspaceOrderStore {
    /// The `UserDefaults` key holding the JSON map.
    public static let defaultsKey = "supermux.workspaceOrder.keys.v1"
    /// The entry count past which the reconciler prunes again.
    public static let defaultCapacity = 2048

    /// Every stored key, by the workspace's stable id.
    public private(set) var keys: [UUID: String]

    private let defaults: UserDefaults
    private let defaultsKey: String
    private let capacity: Int
    private let orderKey = SupermuxOrderKey()

    /// Loads the persisted map (a missing or corrupt value starts empty).
    /// - Parameters:
    ///   - defaults: The defaults domain to persist into: the app's own.
    ///   - defaultsKey: The defaults key.
    ///   - capacity: The entry count past which ``isOverCapacity`` holds.
    public init(
        defaults: UserDefaults,
        defaultsKey: String = SupermuxWorkspaceOrderStore.defaultsKey,
        capacity: Int = SupermuxWorkspaceOrderStore.defaultCapacity
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.capacity = max(1, capacity)
        keys = Self.load(defaults: defaults, key: defaultsKey, orderKey: orderKey)
    }

    /// The stored key of a workspace.
    /// - Parameter stableID: The workspace's `stableId`.
    /// - Returns: Its key, or `nil` when it has none yet.
    public func key(forStableID stableID: UUID) -> String? {
        keys[stableID]
    }

    /// Stores new keys, ignoring any that are not valid, and persists once.
    /// - Parameter newKeys: Keys by the workspace's `stableId`.
    public func setKeys(_ newKeys: [UUID: String]) {
        var changed = false
        for (stableID, key) in newKeys where orderKey.isValid(key) && keys[stableID] != key {
            keys[stableID] = key
            changed = true
        }
        if changed { save() }
    }

    /// Stores one workspace's key (ignored when it is not valid).
    /// - Parameters:
    ///   - key: The new key.
    ///   - stableID: The workspace's `stableId`.
    public func setKey(_ key: String, forStableID stableID: UUID) {
        setKeys([stableID: key])
    }

    /// Drops one workspace's key, so the next capture keys it where it sits.
    /// - Parameter stableID: The workspace's `stableId`.
    public func removeKey(forStableID stableID: UUID) {
        guard keys.removeValue(forKey: stableID) != nil else { return }
        save()
    }

    /// Whether the store holds more entries than its capacity, so it should
    /// be pruned to the live workspaces.
    public var isOverCapacity: Bool {
        keys.count > capacity
    }

    /// Drops every key whose workspace is gone. Call only once the session
    /// restore has finished, or restored workspaces lose their keys.
    /// - Parameter live: The `stableId` of every workspace this Mac owns.
    public func prune(keepingStableIDs live: Set<UUID>) {
        let kept = keys.filter { live.contains($0.key) }
        guard kept.count != keys.count else { return }
        keys = kept
        save()
    }

    private func save() {
        let encoded = Dictionary(uniqueKeysWithValues: keys.map { ($0.key.uuidString, $0.value) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private static func load(defaults: UserDefaults, key: String, orderKey: SupermuxOrderKey) -> [UUID: String] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var keys: [UUID: String] = [:]
        for (rawID, orderKeyValue) in decoded {
            guard let stableID = UUID(uuidString: rawID), orderKey.isValid(orderKeyValue) else { continue }
            keys[stableID] = orderKeyValue
        }
        return keys
    }
}
