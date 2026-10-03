public import Foundation

/// How a "which Mac" chip looks, from what is known about that Mac's link.
///
/// A flat sidebar row knows only the Mac's NAME (upstream's "Workspace on %@"
/// label), so ``resolve(name:among:)`` looks it up among the known devices:
///
/// ```swift
/// let state = SupermuxDeviceChipState.resolve(name: "MacBook", among: devices)
/// SupermuxDeviceChip(name: "MacBook", state: state)   // dimmed unless .online
/// ```
public enum SupermuxDeviceChipState: Equatable, Sendable {
    /// The link is live (or nothing proves otherwise).
    case online
    /// The link is dialing or backing off.
    case connecting
    /// The Mac is unreachable.
    case offline

    /// One known device, as the lookup needs it.
    public struct Candidate: Equatable, Sendable {
        public let name: String
        public let machineID: String
        public let state: SupermuxDeviceChipState

        public init(name: String, machineID: String, state: SupermuxDeviceChipState) {
            self.name = name
            self.machineID = machineID
            self.state = state
        }
    }

    /// Whether the chip renders dimmed.
    public var isDimmed: Bool { self != .online }

    /// The state of the Mac named `name` (a device name, or the machine id a
    /// label falls back to). Any same-named connected Mac makes it online; a
    /// name no device carries is never dimmed, since nothing proves that Mac
    /// is down (a renamed Mac, a restored mirror before its device is listed,
    /// a label naming several Macs).
    public static func resolve(name: String, among devices: [Candidate]) -> Self {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return .online }
        let matches = devices.filter { $0.name == wanted || $0.machineID == wanted }
        if matches.isEmpty || matches.contains(where: { $0.state == .online }) { return .online }
        return matches.contains { $0.state == .connecting } ? .connecting : .offline
    }
}
