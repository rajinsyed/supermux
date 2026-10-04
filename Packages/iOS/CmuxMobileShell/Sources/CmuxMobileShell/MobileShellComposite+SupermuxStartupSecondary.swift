// SUPERMUX:begin mobile-startup-parallel-secondary (at launch the other Macs dial beside the foreground one — see SUPERMUX-TOUCHPOINTS.md)
import CmuxMobilePairedMac
import Foundation

@MainActor
extension MobileShellComposite {
    /// At launch, the other saved Macs dial beside the foreground candidate
    /// instead of after it connects (field: about 0.6 s later plus their own
    /// dial). The candidate is reserved, so the secondary pass skips it. A
    /// later candidate the pass already connected gives that session up
    /// first, so the foreground can take its control lane.
    /// - Parameter isLaunchRestore: The app's startup restore (it hydrates
    ///   the paired Macs); recovery and connection-method changes keep
    ///   upstream's order.
    func supermuxReserveStartupForegroundCandidate(_ mac: MobilePairedMac, isLaunchRestore: Bool) async {
        guard isLaunchRestore, !didFinishStoredMacReconnectAttempt, multiMacAggregationEnabled else { return }
        let key = MacPairingKey(mac)
        let isFirstCandidate = supermuxStartupForegroundCandidate == nil
        // A launch led by a legacy (non-Iroh) Mac, or by an explicit Tailscale
        // choice, keeps upstream's order: that reconnect may end in update
        // guidance or a strict failure without dialing any other Mac.
        guard !isFirstCandidate
            || (mac.routes.contains(where: { $0.kind == .iroh }) && connectionMethod(for: mac) != .tailscale)
        else { return }
        supermuxStartupForegroundCandidate = key
        if let subscription = secondaryMacSubscriptions[key] {
            await retireSecondaryControlOwner(subscription, shouldRetry: false)
        }
        if isFirstCandidate { scheduleSecondaryAggregation() }
    }

    /// Whether a secondary pass runs beside the launch reconnect. It dials
    /// from the local paired-Mac store instead of joining the launch's backup
    /// refresh (a network fetch); the pass upstream schedules once the
    /// reconnect connects still reconciles the backup.
    var supermuxIsLaunchSecondaryPass: Bool {
        isReconnectingStoredMac && !didFinishStoredMacReconnectAttempt
            && supermuxStartupForegroundCandidate != nil
    }

    /// Whether the launch reconnect is dialing `mac` as its foreground.
    func supermuxIsStartupForegroundCandidate(_ mac: MobilePairedMac) -> Bool {
        isReconnectingStoredMac && supermuxStartupForegroundCandidate == MacPairingKey(mac)
    }
}
// SUPERMUX:end mobile-startup-parallel-secondary
