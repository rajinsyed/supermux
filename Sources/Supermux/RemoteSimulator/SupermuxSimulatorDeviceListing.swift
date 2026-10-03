import CmuxSimulator
import CmuxSimulatorUI
import Foundation

/// How this Mac answers another Mac's (or the phone's)
/// `mobile.simulator.devices.list` for one Simulator panel (the
/// `simulator-devices-list-bounded` touchpoint).
///
/// - It waits at most ``replyBound``, well inside the device link's 20 s
///   reply deadline. A list it could not confirm in that time goes out with
///   `slow: true`, and the viewer asks again.
/// - Once the panel has a device (or a status), the answer refreshes the
///   panel's own list, as upstream did, so a simulator created since appears
///   and can be chosen. It is current only when that refresh landed: a
///   refresh another one superseded selected nothing.
/// - While the panel has neither (not started, or its startup discovery still
///   runs), a refresh of the panel would supersede that discovery, which
///   `simulator-startup-discovery-retry` then repeats and which supersedes the
///   menu's refresh back: the menu read an empty list as current, and with a
///   slow discovery the two could go on for as long as the viewer asked. So the
///   answer reads the list beside the panel and marks the device the panel will
///   show (its saved or requested one).
/// - A refresh or read that outlasted the bound answers the next ask, so a
///   slow Mac still gets its list across.
@MainActor
enum SupermuxSimulatorDeviceListing {
    static let replyBound: Duration = .seconds(8)
    /// How long a refresh or read that outlasted ``replyBound`` stays the
    /// answer for the next ask (the viewer asks again 3 s after a slow reply).
    static let slowResultReuse: Duration = .seconds(20)

    /// The devices the answer lists, the one it marks, and whether the list is current.
    struct Listing {
        let devices: [SimulatorDevice]
        let selectedID: String?
        let current: Bool
    }

    /// The panel refresh still running, per panel (keyed by its coordinator).
    private static var refreshes: [ObjectIdentifier: Task<Bool, Never>] = [:]
    /// The list read beside a starting panel still running, per panel.
    private static var reads: [ObjectIdentifier: Task<[SimulatorDevice]?, Never>] = [:]
    /// When a refresh that outlasted ``replyBound`` landed, per panel.
    private static var slowRefreshesLanded: [ObjectIdentifier: ContinuousClock.Instant] = [:]
    /// A read that outlasted ``replyBound``, and when it finished, per panel.
    private static var slowReads: [ObjectIdentifier: (devices: [SimulatorDevice], at: ContinuousClock.Instant)] = [:]

    static func listing(for panel: SimulatorPanel) async -> Listing {
        let coordinator = panel.coordinator
        guard coordinator.selectedDeviceID != nil || coordinator.status != .idle else {
            return await listingBeside(panel)
        }
        let current = await refreshed(coordinator)
        return Listing(devices: coordinator.devices, selectedID: coordinator.selectedDeviceID, current: current)
    }

    /// The reply: the devices, plus `slow: true` when the list may be out of date.
    static func reply(devices: [[String: Any]], current: Bool) -> [String: Any] {
        current ? ["devices": devices] : ["devices": devices, "slow": true]
    }

    // MARK: - A panel that has a device

    private static func refreshed(_ coordinator: SimulatorPaneCoordinator) async -> Bool {
        let key = ObjectIdentifier(coordinator)
        if refreshes[key] == nil,
           let landed = slowRefreshesLanded.removeValue(forKey: key),
           landed.duration(to: .now) < slowResultReuse {
            return coordinator.failure?.code != SupermuxSimulatorSlow.code
        }
        let refresh = refreshes[key] ?? startRefresh(coordinator, key: key)
        guard let landed = await value(of: refresh, within: replyBound) else { return false }
        return landed && coordinator.failure?.code != SupermuxSimulatorSlow.code
    }

    private static func startRefresh(_ coordinator: SimulatorPaneCoordinator, key: ObjectIdentifier) -> Task<Bool, Never> {
        let started = ContinuousClock.now
        let refresh = Task { @MainActor in
            let landed = await coordinator.reloadDevices()
            refreshes[key] = nil
            if landed, started.duration(to: .now) > replyBound {
                slowRefreshesLanded[key] = .now
            }
            return landed
        }
        refreshes[key] = refresh
        return refresh
    }

    // MARK: - A panel that is starting

    private static func listingBeside(_ panel: SimulatorPanel) async -> Listing {
        let key = ObjectIdentifier(panel.coordinator)
        if reads[key] == nil,
           let slow = slowReads.removeValue(forKey: key),
           slow.at.duration(to: .now) < slowResultReuse {
            return Listing(devices: shown(slow.devices), selectedID: panel.selectedDeviceID, current: true)
        }
        let read = reads[key] ?? startRead(key: key)
        guard let devices = await value(of: read, within: replyBound) ?? nil else {
            return Listing(devices: panel.coordinator.devices, selectedID: panel.selectedDeviceID, current: false)
        }
        return Listing(devices: shown(devices), selectedID: panel.selectedDeviceID, current: true)
    }

    private static func startRead(key: ObjectIdentifier) -> Task<[SimulatorDevice]?, Never> {
        let started = ContinuousClock.now
        let read = Task { @MainActor in
            let devices = try? await SupermuxSimulatorControl.listDevices()
            reads[key] = nil
            if let devices, started.duration(to: .now) > replyBound {
                slowReads[key] = (devices, .now)
            }
            return devices
        }
        reads[key] = read
        return read
    }

    /// What a panel's device menu lists, in its order (upstream's
    /// `SimulatorPaneCoordinator.reloadDevices` filter and private
    /// `simulatorDeviceOrdering`): available iPhones and iPads, booted first,
    /// iPhones first, the most recently booted first, the newest runtime first,
    /// then by name.
    private static func shown(_ devices: [SimulatorDevice]) -> [SimulatorDevice] {
        devices
            .filter { $0.isAvailable && ($0.family == .iPhone || $0.family == .iPad) }
            .sorted { lhs, rhs in
                if (lhs.state == .booted) != (rhs.state == .booted) { return lhs.state == .booted }
                if lhs.family != rhs.family { return lhs.family == .iPhone }
                if lhs.lastBootedAt != rhs.lastBootedAt {
                    return (lhs.lastBootedAt ?? .distantPast) > (rhs.lastBootedAt ?? .distantPast)
                }
                if lhs.runtimeName != rhs.runtimeName { return lhs.runtimeName > rhs.runtimeName }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: - Waiting

    /// `task`'s value, or nil when it takes longer than `bound` (it keeps running).
    private static func value<Value: Sendable>(of task: Task<Value, Never>, within bound: Duration) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let once = SupermuxResumeOnce(continuation)
            Task {
                once.resume(with: .success(await task.value))
            }
            Task {
                try? await Task.sleep(for: bound)
                once.resume(with: .success(nil))
            }
        }
    }
}
