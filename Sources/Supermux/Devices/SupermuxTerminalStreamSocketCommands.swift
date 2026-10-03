#if DEBUG
import CmuxSurfaceCatalogModel
import Foundation

/// DEBUG-only `supermux.devices.terminal_stream.*` drivers for
/// `tests/supermux/loopback_terminal_streaming_e2e.py`, routed from
/// ``SupermuxDevicesSocketCommands``:
///
/// - `terminal_stream.stats {machine}`: the link's watched terminals, the
///   `terminal.bytes` bytes it received per remote terminal, and per mirror
///   pane its full replays, resumes and sequence gaps
///   (``SupermuxTerminalStreamWatch/debugStats(sessions:)``).
/// - `terminal_stream.pretend_old_host {enabled}`: this host stops streaming
///   (no `supermux.terminal_stream.v1`, no `terminal.watch`, no resume), as a
///   host that predates it. Takes effect on the link's next connection.
@MainActor
enum SupermuxTerminalStreamSocketCommands {
    static let methodPrefix = "terminal_stream."

    struct HookError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func handles<S: StringProtocol>(_ name: S) -> Bool {
        name.hasPrefix(methodPrefix)
    }

    static func handle<S: StringProtocol>(_ name: S, _ params: [String: Any]) throws -> [String: Any] {
        switch String(name.dropFirst(methodPrefix.count)) {
        case "stats":
            guard let raw = params["machine"] as? String, SurfaceMachineID(rawValue: raw).isDevice,
                  let provider = SupermuxComposition.devices.provider(for: SurfaceMachineID(rawValue: raw)) else {
                throw HookError(message: "machine must name a device")
            }
            return SupermuxTerminalStreamWatch.of(provider.link).debugStats(sessions: provider.sessions)
        case "pretend_old_host":
            guard let enabled = params["enabled"] as? Bool else { throw HookError(message: "enabled is required") }
            SupermuxTerminalStreamDebug.pretendsOldHost = enabled
            return ["enabled": enabled]
        default:
            throw HookError(message: "unknown terminal_stream method \(name)")
        }
    }
}
#endif
