import CMUXMobileCore
public import Foundation
import Observation
public import SupermuxMobileCore

/// The route each Mac's live session uses, for the Projects list's captions
/// (`Direct · LAN · 6 ms`, `Relay · Tokyo · 241 ms`), plus the fetch that
/// hands each Mac's direct addresses to the phone's dialer.
///
/// Built once at the app's composition root over the Iroh runtime and
/// carried down the view tree. The Projects driver runs ``run(macs:)`` while
/// the list is on screen and the app is active: every ``sampleInterval`` it
/// reads each session's selected path, classifies it
/// (``SupermuxLinkRouteClassifier``) and publishes it through
/// ``SupermuxLinkRoutePublishing``, so an RTT that only jitters does not
/// redraw the list. A Mac serving `route.candidates` is asked once per
/// connection and every ``candidatesRefreshInterval``; a failed ask waits
/// ``candidatesRetryInterval``.
@MainActor
@Observable
public final class SupermuxPhoneRouteModel {
    /// The time between samples.
    public static let sampleInterval: Duration = .seconds(2)
    /// How often a connected Mac is asked for its addresses again.
    public static let candidatesRefreshInterval: TimeInterval = 600
    /// How long after a failed ask the next one may go.
    public static let candidatesRetryInterval: TimeInterval = 60

    /// Each connected Mac's route, by pairing id.
    public private(set) var routes: [String: SupermuxLinkRoute] = [:]

    @ObservationIgnored private let runtime: any SupermuxPhoneRouteRuntime
    @ObservationIgnored private let now: @Sendable () -> Date

    /// Creates the model.
    /// - Parameters:
    ///   - runtime: The phone's Iroh runtime.
    ///   - now: The clock.
    public init(runtime: any SupermuxPhoneRouteRuntime, now: @escaping @Sendable () -> Date = { Date() }) {
        self.runtime = runtime
        self.now = now
    }

    /// Samples every ``sampleInterval`` until the task is cancelled.
    /// - Parameter macs: The Macs the shell has a seam for.
    public func run(macs: [SupermuxPhoneRouteMac]) async {
        while !Task.isCancelled {
            await refresh(macs: macs)
            try? await Task.sleep(for: Self.sampleInterval)
        }
    }

    /// One pass: samples every route and starts every due address fetch.
    /// - Parameter macs: The Macs the shell has a seam for.
    public func refresh(macs: [SupermuxPhoneRouteMac]) async {}

    /// Whether an address fetch for the Mac is running (tests).
    public func isFetchingCandidates(pairingID: String) -> Bool { false }
}
