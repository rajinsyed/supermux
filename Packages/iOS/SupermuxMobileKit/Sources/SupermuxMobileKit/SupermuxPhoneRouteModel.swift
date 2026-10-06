import CMUXMobileCore
public import Foundation
import Observation
public import SupermuxMobileCore

/// The route each Mac's live session uses, for the Projects list's captions
/// (`Direct · LAN · 6 ms`, `Relay · Tokyo · 241 ms`), plus the fetch that
/// hands each Mac's direct addresses to the phone's dialer.
///
/// Built once at the app's composition root over the Iroh runtime and
/// carried down the view tree. The shell's root view runs ``run(macs:)``
/// whenever the app is active, on every screen: every ``sampleInterval`` it
/// reads each session's selected path, classifies it against the phone's own
/// interfaces (``SupermuxLinkRouteClassifier``) and publishes it through
/// ``SupermuxLinkRoutePublishing``, so an RTT that only jitters does not
/// redraw the list.
///
/// A Mac serving `route.candidates` is asked on the schedule the Mac shares
/// (``SupermuxRouteCandidateFetchSchedule``): at once on each new connection
/// and each newly admitted session, again 10 min after an answer that
/// settled it, and a minute after one that did not (a failure, an empty
/// list, a Mac that has no address yet), whose addresses stay as they were.
/// A Mac that says its direct paths are off has its addresses forgotten.
@MainActor
@Observable
public final class SupermuxPhoneRouteModel {
    /// The time between samples.
    public static let sampleInterval: Duration = .seconds(2)

    /// Each connected Mac's route, by pairing id.
    public private(set) var routes: [String: SupermuxLinkRoute] = [:]

    /// One Mac's address fetches.
    private struct CandidateFetch {
        var schedule = SupermuxRouteCandidateFetchSchedule()
        var connectionID: ObjectIdentifier?
        var sessionID: String?
        /// Moves with each new connection or session; an answer to an ask
        /// made before does not settle the schedule.
        var generation = 0
    }

    @ObservationIgnored private let runtime: any SupermuxPhoneRouteRuntime
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let localInterfaces: @Sendable () -> [SupermuxLocalInterface]
    @ObservationIgnored private var publishedAt: [String: Date] = [:]
    @ObservationIgnored private var fetches: [String: CandidateFetch] = [:]
    @ObservationIgnored private var generations = 0

    /// Creates the model.
    /// - Parameters:
    ///   - runtime: The phone's Iroh runtime.
    ///   - now: The clock.
    ///   - localInterfaces: The phone's interfaces, which decide whether a
    ///     direct path stays inside its own network.
    public init(
        runtime: any SupermuxPhoneRouteRuntime,
        now: @escaping @Sendable () -> Date = { Date() },
        localInterfaces: @escaping @Sendable () -> [SupermuxLocalInterface] = { SupermuxLocalInterface.current() }
    ) {
        self.runtime = runtime
        self.now = now
        self.localInterfaces = localInterfaces
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
        let sessions = apply(paths, macs: macs, now: time)
        let live = Set(macs.map(\.pairingID))
        fetches = fetches.filter { live.contains($0.key) }
        for mac in macs { fetchCandidatesIfDue(mac, sessionID: sessions[mac.pairingID], now: time) }
    }

    /// Whether an address fetch for the Mac is running (tests).
    public func isFetchingCandidates(pairingID: String) -> Bool {
        fetches[pairingID]?.schedule.inFlight == true
    }

    // MARK: - Routes

    /// Publishes the sampled routes; returns each Mac's admitted session.
    private func apply(_ paths: [SupermuxPhoneLinkPath], macs: [SupermuxPhoneRouteMac], now: Date) -> [String: String] {
        let interfaces = paths.contains { !$0.isRelay } ? localInterfaces() : []
        var next: [String: SupermuxLinkRoute] = [:]
        var sessions: [String: String] = [:]
        for path in paths {
            guard let pairingID = Self.pairingID(of: path, among: macs) else { continue }
            sessions[pairingID] = path.sessionID
            let sample = SupermuxLinkRouteClassifier.classify(
                isRelay: path.isRelay, remoteAddress: path.remoteAddress, rttMs: path.rttMs, now: now,
                localInterfaces: interfaces)
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
        return sessions
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

    private func fetchCandidatesIfDue(_ mac: SupermuxPhoneRouteMac, sessionID: String?, now: Date) {
        guard let caller = mac.candidates, let deviceID = mac.macDeviceID else {
            fetches[mac.pairingID] = nil
            return
        }
        var fetch = fetches[mac.pairingID] ?? CandidateFetch()
        // A new connection, or a session admitted after the one already
        // seen (the phone dialed the Mac again), asks at once.
        let newSession = sessionID != nil && fetch.sessionID != nil && sessionID != fetch.sessionID
        if fetch.connectionID != mac.connectionID || newSession {
            fetch.connectionID = mac.connectionID
            fetch.schedule.connected()
            generations += 1
            fetch.generation = generations
        }
        if let sessionID { fetch.sessionID = sessionID }
        guard fetch.schedule.isDue(at: now) else {
            fetches[mac.pairingID] = fetch
            return
        }
        fetch.schedule.started(at: now)
        fetches[mac.pairingID] = fetch
        let pairingID = mac.pairingID
        let generation = fetch.generation
        let tag = mac.instanceTag
        let runtime = runtime
        Task { [weak self] in
            let answer = await Self.ask(caller, runtime: runtime, macDeviceID: deviceID, instanceTag: tag)
            self?.fetchFinished(pairingID: pairingID, generation: generation, answer: answer)
        }
    }

    /// Asks the Mac and files what it said.
    private nonisolated static func ask(
        _ caller: any SupermuxRouteCandidatesCalling,
        runtime: any SupermuxPhoneRouteRuntime,
        macDeviceID: String,
        instanceTag: String?
    ) async -> SupermuxRouteCandidateFetchSchedule.Answer {
        do {
            let answer = try await caller.routeCandidates()
            return await runtime.supermuxRecordRouteCandidates(answer, macDeviceID: macDeviceID, instanceTag: instanceTag)
        } catch let refusal as SupermuxRouteCandidatesRefusal {
            let answer = SupermuxRouteCandidateFetchSchedule.Answer(errorCode: refusal.code)
            if answer == .directOff {
                await runtime.supermuxForgetRouteCandidates(macDeviceID: macDeviceID, instanceTag: instanceTag)
            }
            return answer
        } catch {
            return .failed
        }
    }

    private func fetchFinished(pairingID: String, generation: Int, answer: SupermuxRouteCandidateFetchSchedule.Answer) {
        guard var fetch = fetches[pairingID] else { return }
        // An answer to an ask made before the current connection or session
        // does not settle it: the Mac's network may have changed since.
        fetch.schedule.finished(fetch.generation == generation ? answer : .failed, at: now())
        fetches[pairingID] = fetch
    }
}
