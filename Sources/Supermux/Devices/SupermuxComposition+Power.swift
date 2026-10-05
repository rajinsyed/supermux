import Foundation

/// App-wide instances for this Mac's sleep, wake and network changes, the
/// "going to sleep" courtesy between Macs, and App Nap while remote sessions
/// are live. Started from ``SupermuxDevicesGlue/activateIfNeeded()``.
@MainActor
extension SupermuxComposition {
    /// This Mac's sleep, wake and network path: the dark gate and the recoveries.
    static let systemPower = SupermuxSystemPower(journal: MobileHostIrxRuntime.journal)

    /// The notice this Mac sends before it sleeps, and how its links treat another Mac's.
    static let sleepCourtesy = SupermuxDeviceSleepCourtesy(journal: MobileHostIrxRuntime.journal)

    /// No App Nap while a phone or Mac session is live.
    static let remoteSessionActivity = SupermuxRemoteSessionActivity()
}
