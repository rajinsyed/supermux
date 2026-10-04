// SUPERMUX:begin mobile-startup-parallel-secondary (at launch the other Macs dial beside the foreground one — see SUPERMUX-TOUCHPOINTS.md)
import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation

/// The Mac one launch reconnect attempt is dialing as foreground.
struct SupermuxStartupForegroundReservation {
    /// The reconnect attempt (`storedMacReconnectGeneration`) that owns it.
    let generation: Int
    /// Upstream's foreground reservation, so aliases of the Mac (an untagged
    /// row, a row sharing its route) conflict exactly as they do once the
    /// foreground connect publishes its own.
    let reservation: ForegroundConnectionAttemptReservation
}

@MainActor
extension MobileShellComposite {
    /// At launch, the other saved Macs dial beside the foreground candidate
    /// instead of after it connects (field: about 0.6 s later plus their own
    /// dial). The candidate is reserved, so the secondary pass skips it and
    /// its aliases. A later candidate the pass already connected gives that
    /// session up first, so the foreground can take its control lane.
    /// - Parameters:
    ///   - isLaunchRestore: The app's startup restore (it hydrates the paired
    ///     Macs); recovery and connection-method changes keep upstream's order.
    ///   - generation: The reconnect attempt dialing `mac`.
    ///   - routes: The routes that attempt dials.
    func supermuxReserveStartupForegroundCandidate(
        _ mac: MobilePairedMac,
        isLaunchRestore: Bool,
        generation: Int,
        routes: [CmxAttachRoute]
    ) async {
        guard isLaunchRestore, !didFinishStoredMacReconnectAttempt, multiMacAggregationEnabled else { return }
        let isFirstCandidate = supermuxStartupForegroundReservation?.generation != generation
        // The parallel pass starts at the first Iroh candidate on the
        // automatic method. A legacy (non-Iroh) Mac or an explicit Tailscale
        // choice keeps upstream's order while it is the candidate: that
        // reconnect may end in update guidance or a strict failure without
        // dialing any other Mac.
        guard !isFirstCandidate
            || (mac.routes.contains(where: { $0.kind == .iroh }) && connectionMethod(for: mac) != .tailscale)
        else { return }
        supermuxStartupForegroundReservation = SupermuxStartupForegroundReservation(
            generation: generation,
            reservation: ForegroundConnectionAttemptReservation(
                id: UUID(),
                requestedMacDeviceID: mac.macDeviceID,
                instanceTagExpectation: macInstanceTagAuthority.expectation(storedInstanceTag: mac.instanceTag),
                routes: routes
            )
        )
        for subscription in supermuxSecondarySessions(sharingPairingOf: mac, routes: routes) {
            await retireSecondaryControlOwner(subscription, shouldRetry: false)
        }
        if isFirstCandidate { scheduleSecondaryAggregation() }
    }

    /// Secondary sessions on `mac`'s pairing or on one of its routes.
    private func supermuxSecondarySessions(
        sharingPairingOf mac: MobilePairedMac,
        routes: [CmxAttachRoute]
    ) -> [SecondaryMacSubscription] {
        secondaryMacSubscriptions.map(\.value).filter { subscription in
            subscription.ownerKey == MacPairingKey(mac)
                || routes.contains { MobileCoreRPCClient.routesSharePhysicalTransport($0, subscription.route) }
        }
    }

    /// The launch reservation, while the reconnect attempt that made it runs.
    private var supermuxCurrentStartupReservation: SupermuxStartupForegroundReservation? {
        guard isReconnectingStoredMac, !didFinishStoredMacReconnectAttempt,
              let reservation = supermuxStartupForegroundReservation,
              reservation.generation == storedMacReconnectGeneration else { return nil }
        return reservation
    }

    /// Whether a secondary pass runs beside the launch reconnect. It dials
    /// from the local paired-Mac store instead of joining the launch's backup
    /// refresh (a network fetch); the pass upstream schedules once the
    /// reconnect connects still reconciles the backup.
    var supermuxIsLaunchSecondaryPass: Bool {
        supermuxCurrentStartupReservation != nil
    }

    /// Whether `mac` (or an alias of it) is what the launch reconnect is
    /// dialing as its foreground.
    func supermuxIsStartupForegroundCandidate(_ mac: MobilePairedMac) -> Bool {
        supermuxCurrentStartupReservation?.reservation.conflicts(with: mac) == true
    }
}
// SUPERMUX:end mobile-startup-parallel-secondary
