import CmuxSimulatorUI
import Foundation

/// How this Mac answers another Mac's (or the phone's)
/// `mobile.simulator.devices.list` (the `simulator-devices-list-bounded`
/// touchpoint): it refreshes the panel's device list for at most
/// ``replyBound``, well inside the device link's 20 s reply deadline, and
/// answers with what the panel has. When that refresh had not finished, or
/// found this Mac's simulators slow, the reply says `slow: true` and the
/// viewer asks again; the refresh keeps running and updates the panel, and
/// the next ask gets its result (a refresh that slow is not started again
/// for that ask).
@MainActor
enum SupermuxSimulatorDeviceListing {
    static let replyBound: Duration = .seconds(8)
    /// How long a refresh that outlasted ``replyBound`` stays the answer for
    /// the next ask (the viewer asks again 3 s after a slow reply).
    static let slowResultReuse: Duration = .seconds(20)

    /// The refresh still running for each panel (keyed by its coordinator),
    /// so a viewer asking again waits for it instead of superseding it.
    private static var refreshes: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// When a refresh that outlasted ``replyBound`` finished, per panel.
    private static var slowRefreshesFinished: [ObjectIdentifier: ContinuousClock.Instant] = [:]

    /// Refreshes `coordinator`'s devices, waiting at most ``replyBound``.
    /// - Returns: Whether the panel's list is current.
    static func reload(_ coordinator: SimulatorPaneCoordinator) async -> Bool {
        let key = ObjectIdentifier(coordinator)
        if refreshes[key] == nil,
           let finished = slowRefreshesFinished.removeValue(forKey: key),
           finished.duration(to: .now) < slowResultReuse {
            return coordinator.failure?.code != SupermuxSimulatorSlow.code
        }
        let refresh = refreshes[key] ?? startRefresh(coordinator, key: key)
        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = SupermuxResumeOnce(continuation)
            Task {
                await refresh.value
                once.resume(with: .success(true))
            }
            Task {
                try? await Task.sleep(for: replyBound)
                once.resume(with: .success(false))
            }
        }
        return finished && coordinator.failure?.code != SupermuxSimulatorSlow.code
    }

    private static func startRefresh(_ coordinator: SimulatorPaneCoordinator, key: ObjectIdentifier) -> Task<Void, Never> {
        let started = ContinuousClock.now
        let refresh = Task { @MainActor in
            await coordinator.reloadDevices()
            refreshes[key] = nil
            if started.duration(to: .now) > replyBound {
                slowRefreshesFinished[key] = .now
            }
        }
        refreshes[key] = refresh
        return refresh
    }

    /// The reply: the devices, plus `slow: true` when the list may be out of date.
    static func reply(devices: [[String: Any]], current: Bool) -> [String: Any] {
        current ? ["devices": devices] : ["devices": devices, "slow": true]
    }
}
