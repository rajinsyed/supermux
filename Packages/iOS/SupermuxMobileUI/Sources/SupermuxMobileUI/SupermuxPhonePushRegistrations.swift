import SupermuxMobileKit

/// Registers the phone's APNs token with EVERY connected Mac that serves
/// `supermux.phone_push.v1` — not only the foreground one — so the Mac that
/// runs the agents can push even if the phone never made it the foreground.
/// Each Mac keeps its own registration record (see
/// ``SupermuxMobilePushRegistrationStore/run(client:capabilities:pairingID:)``).
@MainActor
enum SupermuxPhonePushRegistrations {
    /// Runs one registration loop per Mac until cancelled.
    /// - Parameter seams: The Macs to register with.
    static func run(_ seams: [SupermuxMacSeam]) async {
        let loops = seams.map { seam in
            Task {
                await SupermuxMobilePushRegistrationStore().run(
                    client: SupermuxMacClient(client: seam.client),
                    capabilities: SupermuxMobileCapabilities(hostCapabilities: seam.hostCapabilities),
                    pairingID: seam.pairingID
                )
            }
        }
        await withTaskCancellationHandler {
            for loop in loops {
                await loop.value
            }
        } onCancel: {
            for loop in loops {
                loop.cancel()
            }
        }
    }
}
