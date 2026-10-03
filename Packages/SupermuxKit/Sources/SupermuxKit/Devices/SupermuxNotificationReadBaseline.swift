public import Foundation

/// The notification-feed rows each other Mac last reported read, so a
/// mirrored copy of a notification is marked read only when its row turned
/// read SINCE the previous feed.
///
/// A row the other Mac reported read stays read there forever; applying it on
/// every feed would undo the user's Mark as Unread on the local copy (which is
/// local only). Persisting the baseline keeps that promise across relaunches:
/// the first feed after a launch then applies only rows that turned read while
/// this Mac was away, never ones it had already applied.
///
/// Stored as JSON in the app's own `UserDefaults` domain (builds never share
/// it), bounded per Mac (the other Mac retains at most 1,000 read rows) and
/// across Macs (the least recently changed Mac is dropped first).
///
/// ```swift
/// let newlyRead = baseline.newlyRead(readRowIDs, on: machineID)
/// ```
@MainActor
public final class SupermuxNotificationReadBaseline {
    /// The `UserDefaults` key holding the JSON list.
    public static let defaultsKey = "supermux.devices.notificationReadBaseline.v1"
    /// Rows kept per Mac: the other Mac's own read-row retention.
    public static let defaultMaxRowsPerMachine = 1_000
    /// Macs kept.
    public static let defaultMaxMachines = 16

    private struct Entry: Codable, Equatable {
        let machineID: String
        let readRowIDs: [String]

        private enum CodingKeys: String, CodingKey {
            case machineID = "machine_id"
            case readRowIDs = "read_row_ids"
        }
    }

    /// Least recently changed first.
    private var entries: [Entry]
    private let defaults: UserDefaults
    private let key: String
    private let maxRowsPerMachine: Int
    private let maxMachines: Int

    /// Loads the persisted baseline (a missing or corrupt value starts empty).
    public init(
        defaults: UserDefaults,
        key: String = SupermuxNotificationReadBaseline.defaultsKey,
        maxRowsPerMachine: Int = SupermuxNotificationReadBaseline.defaultMaxRowsPerMachine,
        maxMachines: Int = SupermuxNotificationReadBaseline.defaultMaxMachines
    ) {
        self.defaults = defaults
        self.key = key
        self.maxRowsPerMachine = max(1, maxRowsPerMachine)
        self.maxMachines = max(1, maxMachines)
        entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// Records `readRowIDs` (every row the Mac's latest feed reports read) as
    /// that Mac's baseline and returns the ones that were not read in the
    /// previous baseline: all of them the first time a Mac is seen.
    public func newlyRead(_ readRowIDs: Set<String>, on machineID: String) -> Set<String> {
        let index = entries.firstIndex { $0.machineID == machineID }
        let previous = index.map { Set(entries[$0].readRowIDs) } ?? []
        let newlyRead = readRowIDs.subtracting(previous)
        let entry = Entry(machineID: machineID, readRowIDs: Array(readRowIDs.sorted().prefix(maxRowsPerMachine)))
        guard index.map({ entries[$0] }) != entry else { return newlyRead }
        if let index { entries.remove(at: index) }
        entries.append(entry)
        entries.removeFirst(max(0, entries.count - maxMachines))
        save()
        return newlyRead
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
