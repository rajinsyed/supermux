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
    func supermuxReserveStartupForegroundCandidate(_ mac: MobilePairedMac) async {
        guard !didFinishStoredMacReconnectAttempt, multiMacAggregationEnabled else { return }
        let key = MacPairingKey(mac)
        let isFirstCandidate = supermuxStartupForegroundCandidate == nil
        // A launch led by a legacy (non-Iroh) Mac keeps upstream's order: its
        // reconnect may end in update guidance without dialing anything.
        guard !isFirstCandidate || mac.routes.contains(where: { $0.kind == .iroh }) else { return }
        supermuxStartupForegroundCandidate = key
        if let subscription = secondaryMacSubscriptions[key] {
            await retireSecondaryControlOwner(subscription, shouldRetry: false)
        }
        if isFirstCandidate { scheduleSecondaryAggregation() }
    }

    /// Whether the launch reconnect is dialing `mac` as its foreground.
    func supermuxIsStartupForegroundCandidate(_ mac: MobilePairedMac) -> Bool {
        isReconnectingStoredMac && supermuxStartupForegroundCandidate == MacPairingKey(mac)
    }
}
// SUPERMUX:end mobile-startup-parallel-secondary
