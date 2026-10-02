import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation

/// Holds a mirror browser's navigation to the owning Mac's `localhost:P` for a
/// moment while a same-port forward of P starts, so the page loads as written
/// (``SupermuxDeviceBrowserRoute/loadsAsWritten(_:dataStoreID:)``): its own
/// origin, a secure context, and the hostname a dev app's Turnstile sitekey,
/// cookies and OAuth settings name, instead of upstream's alias.
///
/// BrowserPanel's `device-mirror-browser-on-demand-forward` fence asks
/// ``holds(_:dataStoreID:panel:resume:abandon:)`` before every navigation it
/// performs: typed, `browser.navigate`, a new tab, a link, redirect or reload
/// the `device-mirror-browser-reroute` fence hands back (also an alias page's
/// own reload, ``mayForward(_:machine:)``), a restore. A navigation is held when
/// its URL is `http` on `localhost`, `127.0.0.1` or `[::1]` in a mirror browser,
/// not loaded as written yet, its port P ≥ 1024, the owning Mac can forward,
/// and the user did not stop P's forward. Then, for at most ``wait``:
/// 1. P in use here (by anything but its own forward) keeps the alias;
/// 2. P missing from that Mac's latest listing is asked for again: its other
///    loopback ports change without a poke (a server an agent started), and a
///    headless Mac's sidebar port detection can lag behind a restart;
/// 3. ``SupermuxPortForwards/forwardOnDemand(machine:remotePort:)`` starts the
///    forward, or moves one that landed on another port back to P;
/// 4. the navigation resumes once the forward listens on P, else at the end of
///    the wait through the alias as before (the forward's later activation
///    still moves the tab, ``SupermuxDeviceBrowserRoute/forwardsChanged()``).
/// A newer navigation of the same panel drops the held one. The alias load a
/// held navigation resumes into is not handed back again (``mayForward``
/// lets it pass once), so it is not rerouted in a loop. When the forward
/// cannot start (P in use here, the start refused, or not active in time),
/// the alias page's reloads are left alone for ``standAside``: handed to the
/// panel they would become new navigations, and a page that reloads itself
/// once (Next.js's dev client checks the navigation type) would reload
/// forever. Only a port the owner did not list (its server is down) is tried
/// again on the next reload, which may come once it is up.
@MainActor
enum SupermuxSamePortForwardGate {
    /// The longest a navigation waits for its forward.
    static let wait: Duration = .seconds(3)
    /// How long ``forwardOpenTabs()`` leaves a port it gave up on, and how
    /// long the pass for a resumed alias load lasts.
    static let retryAfter: Duration = .seconds(2)
    /// How long an alias page's reloads stay reloads after a forward could
    /// not start for its port.
    static let standAside: Duration = .seconds(10)
    private static let poll: Duration = .milliseconds(50)

    private struct Target: Hashable {
        let machine: SurfaceMachineID
        let port: Int
    }

    /// How a wait for a forward ended.
    private enum Outcome {
        /// The forward listens on the port and the port is listed: as written.
        case asWritten
        /// That Mac does not list the port (nothing serves it there).
        case unlisted
        /// The port is in use here, the forward did not start, or not in time.
        case unavailable
    }

    private struct Hold {
        let token: UUID
        let abandon: @MainActor () -> Void
    }

    private static var held: [ObjectIdentifier: Hold] = [:]
    /// The panel whose held navigation is resuming: its next check passes.
    private static var resuming: ObjectIdentifier?
    /// When ``forwardOpenTabs()`` last gave a port up.
    private static var gaveUp: [Target: ContinuousClock.Instant] = [:]
    /// Ports whose held navigation just resumed onto the alias: the policy
    /// check of that load passes once (``mayForward``).
    private static var aliasPasses: [Target: ContinuousClock.Instant] = [:]
    /// Ports whose forward could not start: their alias pages' reloads stay
    /// reloads for ``standAside``.
    private static var unavailable: [Target: ContinuousClock.Instant] = [:]

    /// Whether `request` waits for a same-port forward. True when held:
    /// `resume` runs the navigation later (it asks again and passes),
    /// `abandon` reports that it never started (a newer navigation of the
    /// panel came first).
    static func holds(
        _ request: URLRequest, dataStoreID: UUID?, panel: AnyObject,
        resume: @escaping @MainActor () -> Void, abandon: @escaping @MainActor () -> Void
    ) -> Bool {
        let id = ObjectIdentifier(panel)
        if resuming == id {
            resuming = nil
            return false
        }
        held.removeValue(forKey: id)?.abandon()
        // Cheap first: most navigations are not to a loopback port.
        guard let url = request.url, loopbackPort(url) != nil,
              let machine = dataStoreID.flatMap(SupermuxDeviceBrowserRoute.machine(forDataStore:)),
              let target = target(url, machine: machine) else { return false }
        let token = UUID()
        held[id] = Hold(token: token, abandon: abandon)
        Task { @MainActor in
            let outcome = await prepare(target)
            guard held[id]?.token == token else { return }
            held[id] = nil
            note(outcome, for: target)
            if outcome != .asWritten { aliasPasses[target] = .now }
            #if DEBUG
            cmuxDebugLog("supermux.ports.onDemand port=\(target.port) outcome=\(outcome)")
            #endif
            resuming = id
            resume()
            if resuming == id { resuming = nil }
        }
        return true
    }

    /// Targets ``forwardOpenTabs()`` is starting a forward for.
    private static var starting: Set<Target> = []

    /// After a change of the forwards or the Macs' listings
    /// (``SupermuxPortForwards/onChange``): every open mirror tab on the alias
    /// of a port its Mac lists now gets a same-port forward, as a navigation
    /// to it would (no wait: the tab is not navigating). Once the forward is
    /// active ``SupermuxDeviceBrowserRoute/forwardsChanged()`` moves the tab to
    /// `localhost`. So a tab that landed on the alias while its server
    /// restarted comes back on its own once this Mac sees the server again
    /// (the follow-up fetches of ``SupermuxPortForwards/followUpDelays``), also
    /// when the owner lists it only among its other ports.
    static func forwardOpenTabs() {
        let forwards = SupermuxComposition.portForwards
        for machine in SupermuxDeviceBrowserProxies.shared.machines {
            for browser in SupermuxDeviceBrowserProxies.browsers(of: machine) {
                guard let url = browser.webView.url, url.scheme?.lowercased() == "http",
                      RemoteLoopbackProxyAlias.normalizeHost(url.host ?? "") == RemoteLoopbackProxyAlias.aliasHost,
                      var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
                components.host = RemoteLoopbackProxyAlias.canonicalLoopbackHost
                guard let local = components.url, let target = target(local, machine: machine),
                      !starting.contains(target), forwards.lists(machine: machine, port: target.port) else { continue }
                if let last = gaveUp[target], ContinuousClock.now - last < retryAfter { continue }
                starting.insert(target)
                Task { @MainActor in
                    let outcome = await prepare(target)
                    starting.remove(target)
                    note(outcome, for: target)
                    if outcome != .asWritten { gaveUp[target] = .now }
                }
            }
        }
    }

    /// Whether an alias page of `url`'s port (`url` on `localhost`) may go back
    /// to the panel to start a same-port forward (the reroute fence, for a
    /// reload or a link on the alias page): what ``holds`` would hold, except
    /// the one alias load a held navigation just resumed into.
    static func mayForward(_ url: URL, machine: SurfaceMachineID) -> Bool {
        guard let target = target(url, machine: machine) else { return false }
        if let resumed = aliasPasses.removeValue(forKey: target), ContinuousClock.now - resumed < retryAfter { return false }
        if let last = unavailable[target], ContinuousClock.now - last < standAside { return false }
        return true
    }

    private static func note(_ outcome: Outcome, for target: Target) {
        if outcome == .unavailable {
            unavailable[target] = .now
        } else {
            unavailable[target] = nil
        }
    }

    /// The port a navigation to `url` in `machine`'s mirror browser may get a
    /// same-port forward for, or nil.
    private static func target(_ url: URL, machine: SurfaceMachineID) -> Target? {
        guard let port = loopbackPort(url) else { return nil }
        let forwards = SupermuxComposition.portForwards
        guard port >= SupermuxPortForwardPlan.lowestAutomaticPort,
              !SupermuxDeviceBrowserRoute.asWrittenPorts(of: machine).contains(port),
              forwards.availability[machine] == .available,
              !forwards.isStoppedByUser(machine: machine, remotePort: port) else { return nil }
        return Target(machine: machine, port: port)
    }

    /// The port of an `http` URL on `localhost`, `127.0.0.1` or `[::1]`.
    private static func loopbackPort(_ url: URL) -> Int? {
        guard url.scheme?.lowercased() == "http",
              let host = RemoteLoopbackProxyAlias.normalizeHost(url.host ?? ""),
              ["localhost", "127.0.0.1", "::1"].contains(host) else { return nil }
        return url.port ?? 80
    }

    /// Starts or waits for the forward, within ``wait``.
    private static func prepare(_ target: Target) async -> Outcome {
        let forwards = SupermuxComposition.portForwards
        let deadline = ContinuousClock.now + wait
        let (machine, port) = (target.machine, target.port)
        if forwards.localPort(machine: machine, remotePort: port) != port,
           await SupermuxLocalPortProbe.isInUse(port) {
            return .unavailable
        }
        if !forwards.lists(machine: machine, port: port) {
            let fetched = Flag()
            Task { @MainActor in
                await forwards.fetchListingNow(machine)
                fetched.isSet = true
            }
            await waitUntil(deadline) { fetched.isSet || forwards.lists(machine: machine, port: port) }
            guard forwards.lists(machine: machine, port: port) else { return .unlisted }
        }
        guard forwards.localPort(machine: machine, remotePort: port) == port
            || forwards.forwardOnDemand(machine: machine, remotePort: port) else { return .unavailable }
        await waitUntil(deadline) {
            switch forwards.forwards[SupermuxPortForwards.Key(machine: machine, remotePort: port)]?.state {
            case .starting?, .waiting?: return false
            default: return true
            }
        }
        return SupermuxDeviceBrowserRoute.asWrittenPorts(of: machine).contains(port) ? .asWritten : .unavailable
    }

    private static func waitUntil(_ deadline: ContinuousClock.Instant, _ done: () -> Bool) async {
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: poll)
        }
    }

    @MainActor
    private final class Flag {
        var isSet = false
    }
}
