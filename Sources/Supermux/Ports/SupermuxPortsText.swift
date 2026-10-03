import Foundation

/// The words the port menus, Settings and pills share for another Mac's ports.
@MainActor
enum SupermuxPortsText {
    /// Why `macName`'s ports cannot be forwarded right now; nil when they can.
    static func unavailable(_ availability: SupermuxDeviceTunnelAvailability?, macName: String) -> String? {
        switch availability {
        case .available:
            return nil
        case .needsUpdate:
            return String(
                localized: "supermux.ports.unavailable.update",
                defaultValue: "Update Supermux on \(macName) to use its ports here."
            )
        case .noDirectLink:
            return String(
                localized: "supermux.ports.unavailable.directLink",
                defaultValue: "Port forwarding needs a direct connection to \(macName)."
            )
        case .unreachable:
            return String(
                localized: "supermux.ports.unavailable.unreachable",
                defaultValue: "Can't reach \(macName) right now. Trying again…"
            )
        case .offline, nil:
            return String(localized: "supermux.ports.unavailable.offline", defaultValue: "\(macName) is offline.")
        }
    }

    /// Why a mirror's port chip opens nothing outside cmux: the port has no
    /// active forward on this Mac.
    static func notForwarded(remotePort: Int, macName: String) -> String {
        String(
            localized: "supermux.ports.chip.notForwarded",
            defaultValue: "Port \(String(remotePort)) from \(macName) isn't forwarded to this Mac. Forward it with Ports on \(macName) › Forward to This Mac."
        )
    }

    /// A port in a menu: `localhost:3000`, or `localhost:3000 → here :3001`
    /// when it landed on another local port.
    static func menuLabel(remotePort: Int, localPort: Int?) -> String {
        guard let localPort, localPort != remotePort else { return "localhost:\(remotePort)" }
        return String(
            localized: "supermux.ports.menu.item.moved",
            defaultValue: "localhost:\(String(remotePort)) → here :\(String(localPort))"
        )
    }

    /// A forward in the Settings line: `:3000`, `:8081 → here :8082`, or why
    /// it does not listen.
    static func lineItem(_ forward: SupermuxPortForwards.Forward) -> String {
        let remote = forward.key.remotePort
        switch forward.state {
        case .active(let local) where local != remote:
            return String(localized: "supermux.ports.line.moved", defaultValue: ":\(String(remote)) → here :\(String(local))")
        case .active, .starting, .waiting:
            return ":\(remote)"
        case .stopped:
            return String(localized: "supermux.ports.line.stopped", defaultValue: ":\(String(remote)) (stopped)")
        case .failed:
            return String(localized: "supermux.ports.line.failed", defaultValue: ":\(String(remote)) (no free port)")
        }
    }
}
