#if DEBUG
import Foundation

/// DEBUG counters of device-mirror terminal input, kept by
/// ``DeviceTerminalInputRouter`` for every mirror pane on this Mac: how many
/// `mobile.terminal.input` requests were sent and how many were awaiting
/// their reply at once. Updated from the router's queue and the main actor,
/// so a lock guards them.
enum SupermuxTerminalInputDebug {
    struct Stats: Sendable {
        var requestsSent = 0
        var inFlight = 0
        var maxInFlight = 0
        var resends = 0
        var pipelinedRequests = 0
        /// Key batches a mirror dropped because it was not attached (typed
        /// while it re-attached or the link was down).
        var droppedWhileDetached = 0
    }

    /// This host withholds `supermux.terminal_input_pipeline.v1`, as a host
    /// that predates it (takes effect on the link's next connection).
    nonisolated(unsafe) static var pretendsOldHost = false

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stats = Stats()

    /// A request is on its way; `pipelined` when it carries a delivery
    /// identity, `resend` when it carries one sent before.
    static func requestStarted(pipelined: Bool = false, resend: Bool = false) {
        lock.withLock {
            stats.requestsSent += 1
            stats.inFlight += 1
            stats.maxInFlight = max(stats.maxInFlight, stats.inFlight)
            if pipelined { stats.pipelinedRequests += 1 }
            if resend { stats.resends += 1 }
        }
    }

    static func requestFinished() {
        lock.withLock { stats.inFlight = max(0, stats.inFlight - 1) }
    }

    /// A mirror pane dropped typed input because it was not attached.
    static func inputDroppedWhileDetached() {
        lock.withLock { stats.droppedWhileDetached += 1 }
    }

    /// The counters; `reset` starts new ones (keeping the requests in flight).
    static func snapshot(reset: Bool) -> Stats {
        lock.withLock {
            let current = stats
            if reset { stats = Stats(inFlight: current.inFlight) }
            return current
        }
    }
}

/// DEBUG-only `supermux.devices.terminal_input.*` drivers for
/// `tests/supermux/loopback_terminal_input_pipeline_e2e.py`, routed from
/// ``SupermuxDevicesSocketCommands``:
///
/// - `terminal_input.stats {reset?}`: ``SupermuxTerminalInputDebug`` counters
///   (requests sent, in flight now, most in flight at once, resends, key
///   batches dropped because the mirror was not attached).
/// - `terminal_input.latency {to_host_ms?, to_viewer_ms?}`: one-way latency
///   of the loopback device's link (``SupermuxDeviceLoopbackLatency``), so
///   typing runs over a slow link; 0 turns it off.
/// - `terminal_input.pretend_old_host {enabled}`: this host withholds
///   `supermux.terminal_input_pipeline.v1`; takes effect on the next connection.
@MainActor
enum SupermuxTerminalInputSocketCommands {
    static let methodPrefix = "terminal_input."

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
            let stats = SupermuxTerminalInputDebug.snapshot(reset: params["reset"] as? Bool ?? false)
            return [
                "requests_sent": stats.requestsSent,
                "in_flight": stats.inFlight,
                "max_in_flight": stats.maxInFlight,
                "resends": stats.resends,
                "pipelined_requests": stats.pipelinedRequests,
                "dropped_while_detached": stats.droppedWhileDetached,
            ]
        case "latency":
            if let toHost = milliseconds(params["to_host_ms"]) {
                SupermuxDeviceLoopbackLatency.toHost = toHost
            }
            if let toViewer = milliseconds(params["to_viewer_ms"]) {
                SupermuxDeviceLoopbackLatency.toViewer = toViewer
            }
            return [
                "to_host_ms": milliseconds(of: SupermuxDeviceLoopbackLatency.toHost),
                "to_viewer_ms": milliseconds(of: SupermuxDeviceLoopbackLatency.toViewer),
            ]
        case "pretend_old_host":
            guard let enabled = params["enabled"] as? Bool else { throw HookError(message: "enabled is required") }
            SupermuxTerminalInputDebug.pretendsOldHost = enabled
            return ["enabled": enabled]
        default:
            throw HookError(message: "unknown terminal_input method \(name)")
        }
    }

    private static func milliseconds(_ value: Any?) -> Duration? {
        guard let number = value as? NSNumber else { return nil }
        return .milliseconds(min(max(number.intValue, 0), 10_000))
    }

    private static func milliseconds(of duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
    }
}
#endif
