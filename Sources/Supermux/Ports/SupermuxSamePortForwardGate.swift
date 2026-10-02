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
/// A newer navigation of the same panel drops the held one. A navigation that
/// ends on the alias this way is not handed back again for ``retryAfter``, so
/// the alias page it loads is not rerouted in a loop.
@MainActor
enum SupermuxSamePortForwardGate {
    /// The longest a navigation waits for its forward.
    static let wait: Duration = .seconds(3)
    /// How long an alias page of a port the gate gave up on stays there.
    static let retryAfter: Duration = .seconds(2)
    private static let poll: Duration = .milliseconds(50)

    private struct Target: Hashable {
        let machine: SurfaceMachineID
        let port: Int
    }

    private struct Hold {
        let token: UUID
        let abandon: @MainActor () -> Void
    }

    private static var held: [ObjectIdentifier: Hold] = [:]
    /// The panel whose held navigation is resuming: its next check passes.
    private static var resuming: ObjectIdentifier?
    /// When the gate last let a port go through the alias.
    private static var gaveUp: [Target: ContinuousClock.Instant] = [:]

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
        guard let url = request.url, let machine = dataStoreID.flatMap(SupermuxDeviceBrowserRoute.machine(forDataStore:)),
              let target = target(url, machine: machine) else { return false }
        let token = UUID()
        held[id] = Hold(token: token, abandon: abandon)
        Task { @MainActor in
            let forwarded = await prepare(target)
            guard held[id]?.token == token else { return }
            held[id] = nil
            if !forwarded { gaveUp[target] = .now }
            #if DEBUG
            cmuxDebugLog("supermux.ports.onDemand port=\(target.port) asWritten=\(forwarded)")
            #endif
            resuming = id
            resume()
            if resuming == id { resuming = nil }
        }
        return true
    }

    /// Whether an alias page of `url`'s port (`url` on `localhost`) may go back
    /// to the panel to start a same-port forward: what ``holds`` would hold,
    /// unless the gate gave that port up within ``retryAfter``.
    static func mayForward(_ url: URL, machine: SurfaceMachineID) -> Bool {
        guard let target = target(url, machine: machine) else { return false }
        if let last = gaveUp[target], ContinuousClock.now - last < retryAfter { return false }
        return true
    }

    /// The port a navigation to `url` in `machine`'s mirror browser may get a
    /// same-port forward for, or nil.
    private static func target(_ url: URL, machine: SurfaceMachineID) -> Target? {
        guard url.scheme?.lowercased() == "http",
              let host = RemoteLoopbackProxyAlias.normalizeHost(url.host ?? ""),
              ["localhost", "127.0.0.1", "::1"].contains(host) else { return nil }
        let port = url.port ?? 80
        let forwards = SupermuxComposition.portForwards
        guard port >= SupermuxPortForwardPlan.lowestAutomaticPort,
              !SupermuxDeviceBrowserRoute.asWrittenPorts(of: machine).contains(port),
              forwards.availability[machine] == .available,
              !forwards.isStoppedByUser(machine: machine, remotePort: port) else { return nil }
        return Target(machine: machine, port: port)
    }

    /// Starts or waits for the forward, within ``wait``; true once it
    /// listens on the port itself and the port is listed.
    private static func prepare(_ target: Target) async -> Bool {
        let forwards = SupermuxComposition.portForwards
        let deadline = ContinuousClock.now + wait
        let (machine, port) = (target.machine, target.port)
        if forwards.localPort(machine: machine, remotePort: port) != port,
           await SupermuxLocalPortProbe.isInUse(port) {
            return false
        }
        if !forwards.lists(machine: machine, port: port) {
            let fetched = Flag()
            Task { @MainActor in
                await forwards.fetchListingNow(machine)
                fetched.isSet = true
            }
            await waitUntil(deadline) { fetched.isSet || forwards.lists(machine: machine, port: port) }
            guard forwards.lists(machine: machine, port: port) else { return false }
        }
        guard forwards.localPort(machine: machine, remotePort: port) == port
            || forwards.forwardOnDemand(machine: machine, remotePort: port) else { return false }
        await waitUntil(deadline) {
            switch forwards.forwards[SupermuxPortForwards.Key(machine: machine, remotePort: port)]?.state {
            case .starting?, .waiting?: return false
            default: return true
            }
        }
        return SupermuxDeviceBrowserRoute.asWrittenPorts(of: machine).contains(port)
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
