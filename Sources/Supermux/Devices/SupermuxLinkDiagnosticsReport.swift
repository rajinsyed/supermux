import CmuxIrxTransport
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// The Supermux section at the end of `cmux iroh-diag` (the `iroh-diag-links`
/// touchpoint in `TerminalController.irohDiagText`): which path each remote
/// Mac's link uses now, the link history and the transport journal's counters.
///
/// Upstream's report is the host's `DiagnosticLog` ring, which on a Mac fills
/// with terminal layout events (4,096 of them in about an hour) and never
/// holds a Mac link's transport events, so it could not show a path, a route
/// change or a reconnect. This section reads the IRX journal instead: its own
/// link-history ring (`IrxJournal.supermuxLinkHistory`: route, device-link,
/// power and connection events, which the chatty components cannot evict)
/// and its counters (dials, closes, keepalive misses, route moves, terminal
/// replays: `replay-full`, `replay-resumed`). Every line after a heading is
/// one JSON object, the journal's own shape for events, so it greps and
/// parses like the journal file. Nothing here waits for the main actor:
/// the verb must work while the main thread is wedged.
enum SupermuxLinkDiagnosticsReport {
    /// The section for this app's journal and route store.
    nonisolated static func text() -> String {
        text(
            journal: MobileHostIrxRuntime.journal,
            routes: SupermuxComposition.deviceRoutes.offMainRoutes.withLock { $0 }
        )
    }

    /// The section for a journal and the published routes.
    nonisolated static func text(journal: IrxJournal, routes: [SurfaceDeviceInstanceID: SupermuxLinkRoute]) -> String {
        var lines = [String(localized: "supermux.diag.links.title", defaultValue: "Remote Mac links")]
        lines.append(String(localized: "supermux.diag.links.routes", defaultValue: "Routes now"))
        let routeLines = routes
            .sorted { $0.key.description < $1.key.description }
            .map { json(routeObject($0.value, for: $0.key)) }
        lines.append(contentsOf: routeLines.isEmpty
            ? [String(localized: "supermux.diag.links.none", defaultValue: "None")]
            : routeLines)
        lines.append(String(localized: "supermux.diag.links.history", defaultValue: "Link history, oldest first"))
        let history = journal.supermuxLinkHistory()
        lines.append(contentsOf: history.isEmpty
            ? [String(localized: "supermux.diag.links.none", defaultValue: "None")]
            : history.map(IrxJournal.render))
        lines.append(String(localized: "supermux.diag.links.counters", defaultValue: "Transport journal counters"))
        lines.append(json(journal.counterSnapshot()))
        if let path = journal.fileURL?.path {
            lines.append(String(localized: "supermux.diag.links.journal", defaultValue: "Full journal: \(path)"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `supermux.devices.list`'s route shape, with the device it belongs to
    /// (its id prefix and tag, as the journal names it).
    private nonisolated static func routeObject(_ route: SupermuxLinkRoute, for instance: SurfaceDeviceInstanceID) -> [String: Any] {
        var object = SupermuxDevicesSocketPayloads.route(route) as? [String: Any] ?? [:]
        object["device"] = String(instance.deviceID.prefix(8))
        object["tag"] = instance.tag
        return object
    }

    private nonisolated static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
