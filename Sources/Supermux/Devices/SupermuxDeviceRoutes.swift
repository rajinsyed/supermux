import CmuxIrxTransport
import CmuxSurfaceCatalogModel
import Foundation
import Observation
import os
import SupermuxMobileCore

/// The route each connected remote Mac's link uses right now: direct (LAN,
/// Tailscale, Internet) or through a relay, with iroh's RTT on it. The one
/// place UI reads it from (the sidebar chip, the Remote Macs card) and
/// `supermux.devices.list` reports. ``offMainRoutes`` mirrors it for
/// `cmux iroh-diag`, which must not wait for the main actor.
///
/// Fed by ``SupermuxDeviceRouteMonitor``; each sample goes through
/// ``SupermuxLinkRoutePublishing``, so ``routes`` changes on a change of kind
/// at once and on an RTT move at most every 5 s. A view holding a value
/// snapshot of one route is not redrawn by RTT jitter.
///
/// ```swift
/// if let route = SupermuxComposition.deviceRoutes.route(for: device) {
///     route.isRelay   // amber dot
///     route.rttMs     // "241 ms"
/// }
/// ```
@MainActor
@Observable
final class SupermuxDeviceRoutes {
    /// The published route of every link that has one.
    private(set) var routes: [SurfaceDeviceInstanceID: SupermuxLinkRoute] = [:]

    /// ``routes``, readable off the main actor: `cmux iroh-diag` reports them
    /// while the main thread is wedged (the case diagnostics exist for).
    nonisolated let offMainRoutes = OSAllocatedUnfairLock(initialState: [SurfaceDeviceInstanceID: SupermuxLinkRoute]())

    @ObservationIgnored private var publishedAt: [SurfaceDeviceInstanceID: Date] = [:]
    @ObservationIgnored private let journal: IrxJournal?

    /// Nonisolated so the composition root can hold it in a nonisolated
    /// static (the diag report reads ``offMainRoutes`` from any thread); it
    /// only stores a journal.
    nonisolated init(journal: IrxJournal?) {
        self.journal = journal
    }

    /// The route of a device's link while it is connected; nil otherwise.
    func route(for device: SupermuxDevice) -> SupermuxLinkRoute? {
        device.isConnected ? routes[device.instance] : nil
    }

    /// Offers a fresh sample; publishes it when the publish rule says so.
    func apply(_ sample: SupermuxLinkRoute, for instance: SurfaceDeviceInstanceID, now: Date = Date()) {
        let published = routes[instance]
        guard let next = SupermuxLinkRoutePublishing.next(
            published: published, publishedAt: publishedAt[instance], sample: sample, now: now
        ) else { return }
        routes[instance] = next
        publishedAt[instance] = now
        mirrorOffMain()
        if published?.kind != next.kind { record(next, for: instance) }
    }

    /// Forgets the route of a link that has none any more (disconnected, or
    /// no selected path yet).
    func clear(_ instance: SurfaceDeviceInstanceID) {
        guard routes[instance] != nil else { return }
        routes[instance] = nil
        publishedAt[instance] = nil
        mirrorOffMain()
        journal?.record("route", "cleared", ["device": String(instance.deviceID.prefix(8)), "tag": instance.tag])
    }

    /// Drops every route whose link is not in `instances`.
    func keepOnly(_ instances: Set<SurfaceDeviceInstanceID>) {
        for instance in routes.keys where !instances.contains(instance) { clear(instance) }
    }

    private func mirrorOffMain() {
        let current = routes
        offMainRoutes.withLock { $0 = current }
    }

    private func record(_ route: SupermuxLinkRoute, for instance: SurfaceDeviceInstanceID) {
        var attributes = [
            "device": String(instance.deviceID.prefix(8)),
            "tag": instance.tag,
            "kind": route.isRelay ? "relay" : "direct",
        ]
        attributes["scope"] = route.scope?.rawValue
        attributes["relay_id"] = route.relayID
        attributes["rtt_ms"] = route.rttMs.map(String.init)
        journal?.record("route", "changed", attributes)
    }
}
