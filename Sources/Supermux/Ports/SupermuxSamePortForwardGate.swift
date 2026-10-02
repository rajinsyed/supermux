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
/// ``holds(_:dataStoreID:typed:panel:resume:abandon:)`` before every navigation
/// it performs: typed, `browser.navigate`, a new tab, a link, redirect or reload
/// the `device-mirror-browser-reroute` fence hands back (also an alias page's own
/// reload, ``mayForward(_:machine:)``), a restore. A navigation is held when its
/// URL is `http` on `localhost`, `127.0.0.1` or `[::1]` in a mirror browser, not
/// loaded as written yet, its port P ≥ 1024, the owning Mac can forward, and the
/// user did not stop P's forward. Then, for at most ``wait``:
/// 1. P in use here (by anything but its own forward) keeps the alias;
/// 2. P missing from that Mac's latest listing is asked for again (one shared
///    fetch per Mac, ``SupermuxPortForwards/fetchListingNow(_:)``): a headless
///    Mac's sidebar port detection can lag behind a restart;
/// 3. only a port of that Mac's workspaces is forwarded for any navigation; one
///    of its other loopback ports (a Docker API, a database, a server an agent
///    started) only for the user's own action, a typed URL, a terminal link they
///    Command-clicked or the Ports menu's Open in cmux Browser
///    (``noteUserOpen(port:)``), or once the user forwarded it that way (a page
///    could otherwise make this Mac listen on any of them);
/// 4. ``SupermuxPortForwards/forwardOnDemand(machine:remotePort:)`` starts the
///    forward, or moves one that landed on another port back to P;
/// 5. the navigation resumes once the forward listens on P, else at the end of
///    the wait through the alias as before (the forward's later activation
///    still moves the tab, ``SupermuxDeviceBrowserRoute/forwardsChanged()``,
///    which leaves a tab whose navigation is held alone).
/// A newer navigation of the same panel drops the held one and cancels its
/// wait. The alias load a held navigation resumes into is not handed back
/// again (``mayForward`` lets it pass once). A port whose forward could not
/// start (in use here, not in time) is not tried again, by a reload of its alias
/// page or in the background, until the user navigates to it again: a reload
/// handed to the panel becomes a new navigation, and a page that reloads itself
/// once (Next.js's dev client checks the navigation type) would reload forever.
/// A port the owner did not list (its server is down), one not tried yet (a tab
/// restored or opened while that Mac was away) and one only listed among its
/// other ports when a page asked (a restarted server its sidebar scan has not
/// attributed to the workspace yet) are tried again once it may be forwarded:
/// by the next reload or in the background (``forwardOpenTabs()``).
@MainActor
enum SupermuxSamePortForwardGate {
    /// The longest a navigation waits for its forward.
    static let wait: Duration = .seconds(3)
    /// How long the pass for a resumed alias load lasts.
    static let passLasts: Duration = .seconds(2)
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
        /// It is one of that Mac's other ports and nobody asked for it as the
        /// user: tried again once it is a workspace's or the user forwards it.
        case notAllowed
        /// The port is in use here, or its forward did not start (in time).
        case unavailable
    }

    private struct Hold {
        let token: UUID
        let task: Task<Void, Never>
        /// Set when a newer navigation drops this one (its wait and any
        /// listing fetch it would start end).
        let dropped: Flag
        let abandon: @MainActor () -> Void
    }

    private static var held: [ObjectIdentifier: Hold] = [:]
    /// The panel whose held navigation is resuming: its next check passes.
    private static var resuming: ObjectIdentifier?
    /// Each port's last outcome.
    private static var outcomes: [Target: Outcome] = [:]
    /// Other ports (in no workspace there) the user forwarded with a typed URL.
    private static var userForwarded: Set<Target> = []
    /// Ports whose held navigation just resumed onto the alias: the policy
    /// check of that load passes once (``mayForward``).
    private static var aliasPasses: [Target: ContinuousClock.Instant] = [:]
    /// Targets ``forwardOpenTabs()`` is starting a forward for.
    private static var starting: Set<Target> = []
    /// Ports the user opened in a mirror browser just now, other than by typing
    /// (``noteUserOpen(port:)``).
    private static var userOpens: [Int: ContinuousClock.Instant] = [:]
    /// How long a noted user open lasts (the browser opens and navigates at once).
    private static let userOpenLasts: Duration = .seconds(5)

    /// The user is opening `localhost:port` in a mirror browser by their own
    /// action (a terminal link they Command-clicked, the Ports menu's Open in cmux
    /// Browser, a port chip): its navigation counts as typed.
    static func noteUserOpen(port: Int) {
        userOpens[port] = .now
    }

    /// `noteUserOpen(url:)` for a loopback `http` URL; any other URL is ignored.
    static func noteUserOpen(url: URL) {
        if let port = loopbackPort(url) { noteUserOpen(port: port) }
    }

    /// Whether `request` waits for a same-port forward. True when held:
    /// `resume` runs the navigation later (it asks again and passes),
    /// `abandon` reports that it never started (a newer navigation of the
    /// panel came first). `typed`: the user typed the URL.
    static func holds(
        _ request: URLRequest, dataStoreID: UUID?, typed: Bool, panel: AnyObject,
        resume: @escaping @MainActor () -> Void, abandon: @escaping @MainActor () -> Void
    ) -> Bool {
        let id = ObjectIdentifier(panel)
        if resuming == id {
            resuming = nil
            return false
        }
        if let previous = held.removeValue(forKey: id) {
            previous.dropped.isSet = true
            previous.task.cancel()
            previous.abandon()
        }
        // Cheap first: most navigations are not to a loopback port.
        guard let url = request.url, let port = loopbackPort(url),
              let machine = dataStoreID.flatMap(SupermuxDeviceBrowserRoute.machine(forDataStore:)),
              let target = target(url, machine: machine) else { return false }
        var typed = typed
        if let opened = userOpens.removeValue(forKey: port), ContinuousClock.now - opened < userOpenLasts { typed = true }
        let token = UUID()
        let dropped = Flag()
        let task = Task { @MainActor in
            let outcome = await prepare(target, typed: typed, dropped: dropped)
            guard !dropped.isSet, held[id]?.token == token else { return }
            held[id] = nil
            outcomes[target] = outcome
            if outcome != .asWritten { aliasPasses[target] = .now }
            #if DEBUG
            cmuxDebugLog("supermux.ports.onDemand port=\(target.port) typed=\(typed) outcome=\(outcome)")
            #endif
            resuming = id
            resume()
            if resuming == id { resuming = nil }
        }
        held[id] = Hold(token: token, task: task, dropped: dropped, abandon: abandon)
        return true
    }

    /// Whether `panel`'s navigation is held: ``SupermuxDeviceBrowserRoute/forwardsChanged()``
    /// must not move it (the held navigation resumes there itself).
    static func isHolding(_ panel: AnyObject) -> Bool {
        held[ObjectIdentifier(panel)] != nil
    }

    /// After a change of the forwards or the Macs' listings
    /// (``SupermuxPortForwards/onChange``): an open mirror tab on the alias of a
    /// port the gate last found unlisted (its server was down there), not allowed
    /// (only an other port then), or never tried (a tab restored or opened while
    /// that Mac was away) gets a same-port forward once it may: its Mac lists the
    /// port as a workspace's, or the user forwarded it before; as a navigation to
    /// it would. ``SupermuxDeviceBrowserRoute/forwardsChanged()`` then moves it to
    /// `localhost`. So a tab that landed on the alias while its server restarted
    /// comes back on its own (the follow-up fetches of
    /// ``SupermuxPortForwards/followUpDelays``), also when the restarted server
    /// is an other port there until its sidebar scan attributes it. Never a port
    /// last found in use here: probing it on every change could take this Mac's
    /// own port while its server restarts.
    static func forwardOpenTabs() {
        let forwards = SupermuxComposition.portForwards
        for machine in SupermuxDeviceBrowserProxies.shared.machines {
            for browser in SupermuxDeviceBrowserProxies.browsers(of: machine) where !isHolding(browser) {
                guard let url = browser.webView.url, let local = localURL(ofAlias: url),
                      let target = target(local, machine: machine), outcomes[target] != .unavailable,
                      !starting.contains(target), mayBeForwarded(target),
                      // Listed: prepare then fetches nothing, so its own change cannot start it again.
                      forwards.lists(machine: machine, port: target.port) else { continue }
                starting.insert(target)
                Task { @MainActor in
                    outcomes[target] = await prepare(target, typed: false, dropped: Flag())
                    starting.remove(target)
                }
            }
        }
    }

    /// Whether an alias page of `url`'s port (`url` on `localhost`) may go back
    /// to the panel to start a same-port forward (the reroute fence, for a
    /// reload or a link on the alias page): what ``holds`` would hold, except
    /// the one alias load a held navigation just resumed into and a port whose
    /// forward could not start (until the user navigates to it again).
    static func mayForward(_ url: URL, machine: SurfaceMachineID) -> Bool {
        guard let target = target(url, machine: machine) else { return false }
        if let resumed = aliasPasses.removeValue(forKey: target), ContinuousClock.now - resumed < passLasts { return false }
        switch outcomes[target] {
        case .unavailable?: return false
        case .notAllowed?: return mayBeForwarded(target)
        default: return true
        }
    }

    /// Whether a navigation the user did not start may forward `target` now:
    /// its Mac lists it as a workspace's, or the user forwarded it before.
    private static func mayBeForwarded(_ target: Target) -> Bool {
        SupermuxComposition.portForwards.listsInWorkspace(machine: target.machine, port: target.port)
            || userForwarded.contains(target)
    }

    /// `url` on the alias, as `localhost`; nil for any other URL.
    private static func localURL(ofAlias url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http",
              RemoteLoopbackProxyAlias.normalizeHost(url.host ?? "") == RemoteLoopbackProxyAlias.aliasHost,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.host = RemoteLoopbackProxyAlias.canonicalLoopbackHost
        return components.url
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

    /// Starts or waits for the forward, within ``wait``; ends early once the
    /// navigation is `dropped`.
    private static func prepare(_ target: Target, typed: Bool, dropped: Flag) async -> Outcome {
        let forwards = SupermuxComposition.portForwards
        let start = ContinuousClock.now
        let deadline = start + wait
        let (machine, port) = (target.machine, target.port)
        // The user's own request, also when that Mac lists the port only later.
        if typed { userForwarded.insert(target) }
        // Its own listener may still be releasing the port (the forward went a
        // moment ago): that is not "in use here".
        await forwards.released(machine: machine, remotePort: port)
        if forwards.localPort(machine: machine, remotePort: port) != port,
           await SupermuxLocalPortProbe.isInUse(port) {
            return .unavailable
        }
        if !forwards.lists(machine: machine, port: port), !dropped.isSet {
            // Not awaited here: the reply may take longer than the wait.
            let fetched = Flag()
            Task { @MainActor in
                await forwards.fetchListingNow(machine, since: start) { !dropped.isSet }
                fetched.isSet = true
            }
            await waitUntil(deadline, dropped) { fetched.isSet || forwards.lists(machine: machine, port: port) }
            guard forwards.lists(machine: machine, port: port) else { return .unlisted }
        }
        guard !dropped.isSet else { return .unavailable }
        guard mayBeForwarded(target) else { return .notAllowed }
        guard forwards.localPort(machine: machine, remotePort: port) == port
            || forwards.forwardOnDemand(machine: machine, remotePort: port) else { return .unavailable }
        await waitUntil(deadline, dropped) {
            switch forwards.forwards[SupermuxPortForwards.Key(machine: machine, remotePort: port)]?.state {
            case .starting?, .waiting?: return false
            default: return true
            }
        }
        return SupermuxDeviceBrowserRoute.asWrittenPorts(of: machine).contains(port) ? .asWritten : .unavailable
    }

    /// Polls `done` until it holds, `deadline` passes or the navigation is `dropped`.
    private static func waitUntil(_ deadline: ContinuousClock.Instant, _ dropped: Flag, _ done: () -> Bool) async {
        while !done(), ContinuousClock.now < deadline, !dropped.isSet {
            try? await Task.sleep(for: poll)
        }
    }

    @MainActor
    private final class Flag {
        var isSet = false
    }
}
