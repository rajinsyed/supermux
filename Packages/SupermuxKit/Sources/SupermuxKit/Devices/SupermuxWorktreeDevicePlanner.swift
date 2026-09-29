public import Foundation

/// Decides the New Worktree sheet's device picker: which Macs it lists, in
/// what order, which can take a create, whether the picker shows at all, and
/// which Mac is preselected. Pure, so the rules are package-tested.
public enum SupermuxWorktreeDevicePlanner {
    /// The picker rows for `project`: This Mac first (when it has a copy), the
    /// other Macs in the project's location order, then one "Set Up on
    /// <Mac>…" row per Mac that lacks the project.
    ///
    /// - Parameters:
    ///   - project: The unified project.
    ///   - availability: Link state by machine id; a Mac missing here falls
    ///     back to its location's online flag.
    ///   - setUpTargets: Macs that could register the project.
    public static func entries(
        for project: SupermuxUnifiedProject,
        availability: [String: SupermuxWorktreeDeviceAvailability],
        setUpTargets: [SupermuxProjectSetupDestination]
    ) -> [SupermuxWorktreeDeviceEntry] {
        var seen: Set<String> = []
        var entries: [SupermuxWorktreeDeviceEntry] = []
        let ordered = project.locations.filter(\.isThisMac) + project.locations.filter { !$0.isThisMac }
        for location in ordered {
            let key = SupermuxWorktreeDeviceEntry.deviceKey(of: location)
            guard seen.insert(key).inserted else { continue }
            entries.append(SupermuxWorktreeDeviceEntry(
                deviceKey: key,
                name: location.device?.name ?? thisMacName,
                availability: location.device.map { availability[$0.machineID] ?? ($0.isOnline ? .online : .offline) }
                    ?? .online,
                action: .create(location)
            ))
        }
        for destination in setUpTargets {
            let key = SupermuxWorktreeDeviceEntry.deviceKey(of: destination)
            guard seen.insert(key).inserted else { continue }
            let device: SupermuxProjectDevice?
            if case .device(let value) = destination { device = value } else { device = nil }
            entries.append(SupermuxWorktreeDeviceEntry(
                deviceKey: key,
                name: destination.name,
                availability: device.map { availability[$0.machineID] ?? ($0.isOnline ? .online : .offline) }
                    ?? .online,
                action: .setUp(destination)
            ))
        }
        return entries
    }

    /// The picker hides when there is nothing to choose: one row in total.
    public static func showsPicker(_ entries: [SupermuxWorktreeDeviceEntry]) -> Bool {
        entries.count > 1
    }

    /// The row to preselect: an explicit choice (the row menu's "New Worktree
    /// on ▸ <Mac>") when that Mac can create, else the last Mac any worktree
    /// was created on when it can create this project now, else the first Mac
    /// that can (This Mac first when it has a copy), else the first project
    /// copy (an offline-only project still opens, and says why).
    public static func defaultEntryID(
        in entries: [SupermuxWorktreeDeviceEntry],
        preferredDeviceKey: String?,
        lastUsedDeviceKey: String?
    ) -> String? {
        let creatable = entries.filter(\.canCreate)
        for key in [preferredDeviceKey, lastUsedDeviceKey].compactMap({ $0 }) {
            if let entry = creatable.first(where: { $0.deviceKey == key }) { return entry.id }
        }
        return creatable.first?.id ?? entries.first(where: { $0.location != nil })?.id
    }

    private static var thisMacName: String {
        String(localized: "supermux.devices.thisMac", defaultValue: "This Mac")
    }
}
