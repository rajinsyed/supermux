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

    /// One Mac's address fetches.
    private struct CandidateFetch {
        var connectionID: ObjectIdentifier?
        var storedAt: Date?
        var attemptedAt: Date?
        var inFlight = false
    }

    @ObservationIgnored private let runtime: any SupermuxPhoneRouteRuntime
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var publishedAt: [String: Date] = [:]
    @ObservationIgnored private var fetches: [String: CandidateFetch] = [:]

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
    public func refresh(macs: [SupermuxPhoneRouteMac]) async {
        let paths = await runtime.supermuxLinkPaths()
        let time = now()
        apply(paths, macs: macs, now: time)
        let live = Set(macs.map(\.pairingID))
        fetches = fetches.filter { live.contains($0.key) }
        for mac in macs { fetchCandidatesIfDue(mac, now: time) }
    }

    /// Whether an address fetch for the Mac is running (tests).
    public func isFetchingCandidates(pairingID: String) -> Bool {
        fetches[pairingID]?.inFlight == true
    }

    // MARK: - Routes

    private func apply(_ paths: [SupermuxPhoneLinkPath], macs: [SupermuxPhoneRouteMac], now: Date) {
        var next: [String: SupermuxLinkRoute] = [:]
        for path in paths {
            guard let pairingID = Self.pairingID(of: path, among: macs) else { continue }
            let sample = SupermuxLinkRouteClassifier.classify(
                isRelay: path.isRelay, remoteAddress: path.remoteAddress, rttMs: path.rttMs, now: now)
            let published = routes[pairingID]
            if let update = SupermuxLinkRoutePublishing.next(
                published: published, publishedAt: publishedAt[pairingID], sample: sample, now: now) {
                next[pairingID] = update
                publishedAt[pairingID] = now
            } else {
                next[pairingID] = published
            }
        }
        publishedAt = publishedAt.filter { next[$0.key] != nil }
        if next != routes { routes = next }
    }

    /// The Mac a session's path belongs to: the exact pairing, else the only
    /// Mac on that device (a pairing and the directory may spell the build
    /// tag differently). Never a guess between two builds on one device.
    private static func pairingID(of path: SupermuxPhoneLinkPath, among macs: [SupermuxPhoneRouteMac]) -> String? {
        let exact = SupermuxMacSeam.pairingID(macDeviceID: path.macDeviceID, instanceTag: path.instanceTag)
        if macs.contains(where: { $0.pairingID == exact }) { return exact }
        let device = cmxCanonicalDeviceID(path.macDeviceID)
        let sameDevice = macs.filter { mac in
            mac.macDeviceID.map { cmxCanonicalDeviceID($0) == device } ?? false
        }
        return sameDevice.count == 1 ? sameDevice[0].pairingID : nil
    }

    // MARK: - Direct addresses

    private func fetchCandidatesIfDue(_ mac: SupermuxPhoneRouteMac, now: Date) {
        guard let caller = mac.candidates, let deviceID = mac.macDeviceID else {
            fetches[mac.pairingID] = nil
            return
        }
        var fetch = fetches[mac.pairingID] ?? CandidateFetch()
        if fetch.connectionID != mac.connectionID {
            fetch = CandidateFetch(connectionID: mac.connectionID, inFlight: fetch.inFlight)
        }
        defer { fetches[mac.pairingID] = fetch }
        guard !fetch.inFlight else { return }
        if let storedAt = fetch.storedAt, now.timeIntervalSince(storedAt) < Self.candidatesRefreshInterval { return }
        if fetch.storedAt == nil, let attemptedAt = fetch.attemptedAt,
           now.timeIntervalSince(attemptedAt) < Self.candidatesRetryInterval { return }
        fetch.inFlight = true
        fetch.attemptedAt = now
        let pairingID = mac.pairingID
        let connectionID = mac.connectionID
        let tag = mac.instanceTag
        let runtime = runtime
        Task { [weak self] in
            let answer = try? await caller.routeCandidates()
            if let answer {
                await runtime.supermuxRecordRouteCandidates(answer, macDeviceID: deviceID, instanceTag: tag)
            }
            self?.fetchFinished(pairingID: pairingID, connectionID: connectionID, stored: answer != nil)
        }
    }

    private func fetchFinished(pairingID: String, connectionID: ObjectIdentifier?, stored: Bool) {
        guard var fetch = fetches[pairingID] else { return }
        fetch.inFlight = false
        // An answer from a connection that has since been replaced does not
        // count for the new one.
        if stored, fetch.connectionID == connectionID { fetch.storedAt = now() }
        fetches[pairingID] = fetch
    }
}
