import CmuxCloud
import Foundation

/// Retries a device's declined notification rows on a short timer.
///
/// Upstream's admission gate treats every machine, including the user's own
/// Macs, as untrusted: 5 rows at once, then 1 per second. A declined row waits
/// for the NEXT feed fold, which may never come (the agent finished; nothing
/// else changes), so a burst could sit undelivered indefinitely. This refolds
/// the device's last feed shortly after a decline, until the rows land or
/// several attempts in a row make no progress.
@MainActor
final class SupermuxDeviceNotificationRetry {
    /// A little over the gate's one-token-per-second refill.
    static let delay: Duration = .milliseconds(1_200)
    /// Consecutive retries without any delivered row before giving up (the
    /// next feed event or catalog change still refolds as upstream does).
    static let maxAttemptsWithoutProgress = 12

    private var pending: [String: Task<Void, Never>] = [:]
    private var attemptsWithoutProgress: [String: Int] = [:]

    /// Records one delivery outcome for the provider's machine.
    func noteOutcome(_ outcome: CloudNotificationDeliveryOutcome, for provider: DeviceSurfaceProvider) {
        let machineID = provider.machine.rawValue
        switch outcome {
        case .delivered, .suppressed:
            attemptsWithoutProgress[machineID] = 0
        case .declined:
            schedule(for: provider, machineID: machineID)
        }
    }

    /// Pending retries, by machine (DEBUG introspection).
    var pendingMachineIDs: [String] { pending.keys.sorted() }

    private func schedule(for provider: DeviceSurfaceProvider, machineID: String) {
        guard pending[machineID] == nil else { return }
        let attempts = attemptsWithoutProgress[machineID, default: 0]
        guard attempts < Self.maxAttemptsWithoutProgress else { return }
        attemptsWithoutProgress[machineID] = attempts + 1
        pending[machineID] = Task { @MainActor [weak self, weak provider] in
            try? await Task.sleep(for: Self.delay)
            self?.pending[machineID] = nil
            guard !Task.isCancelled, let provider, let sync = provider.notificationSync else { return }
            #if DEBUG
            cmuxDebugLog("supermux.device.notification.retry machine=\(machineID) attempt=\(attempts + 1)")
            #endif
            sync.apply(rows: provider.notificationFeed.rows)
        }
    }
}
