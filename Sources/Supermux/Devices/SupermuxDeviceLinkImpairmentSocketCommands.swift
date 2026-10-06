#if DEBUG
import Foundation

/// DEBUG-only `supermux.devices.link_impairment` for
/// `tests/supermux/loopback_degraded_link_e2e.py`, routed from
/// ``SupermuxDevicesSocketCommands``: makes the loopback device's link slow
/// like a far relay (``SupermuxDeviceLoopbackImpairment``), both directions alike.
///
/// Params (each optional; what is left out stays as it was):
/// - `rtt_ms`: added round trip, half each way (or `to_host_ms` / `to_viewer_ms`,
///   the same delays `terminal_input.latency` sets).
/// - `bytes_per_second`: the capacity of each direction; 0 lifts the cap.
/// - `queue_bytes`: the send buffer before a write waits (default 64 KB).
/// - `drop_every_s`, `drop_for_s`: a drop of `drop_for_s` every `drop_every_s`
///   (the first `drop_every_s` from now); 0 stops them.
/// - `drop_cuts`: whether a drop also closes the live connections (default true).
/// - `drop_now_s`: one drop of that long, starting now.
/// - `reset`: everything off and the counters zeroed (applied first);
///   `reset_stats`: only the counters.
///
/// Answers the settings, whether a drop is on now (`drop_ends_in_ms`), the
/// drops started and connections they cut, and per direction the bytes
/// delivered, queued now and at most, and the writes that waited for room.
@MainActor
enum SupermuxDeviceLinkImpairmentSocketCommands {
    static let method = "link_impairment"

    struct HookError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func handles<S: StringProtocol>(_ name: S) -> Bool {
        name == method
    }

    static func handle(_ params: [String: Any]) throws -> [String: Any] {
        if params["reset"] as? Bool == true { SupermuxDeviceLoopbackImpairment.reset() }
        if params["reset_stats"] as? Bool == true { SupermuxDeviceLoopbackImpairment.resetStats() }
        if let rtt = try milliseconds(params, "rtt_ms") {
            SupermuxDeviceLoopbackLatency.toHost = rtt / 2
            SupermuxDeviceLoopbackLatency.toViewer = rtt / 2
        }
        if let toHost = try milliseconds(params, "to_host_ms") { SupermuxDeviceLoopbackLatency.toHost = toHost }
        if let toViewer = try milliseconds(params, "to_viewer_ms") { SupermuxDeviceLoopbackLatency.toViewer = toViewer }
        var settings = SupermuxDeviceLoopbackImpairment.current
        if let rate = try integer(params, "bytes_per_second") {
            guard rate == 0 || rate >= 1024 else { throw HookError(message: "bytes_per_second must be 0 or at least 1024") }
            settings.bytesPerSecond = rate
        }
        if let queue = try integer(params, "queue_bytes") {
            guard queue >= 1024 else { throw HookError(message: "queue_bytes must be at least 1024") }
            settings.queueBytes = queue
        }
        if let every = try seconds(params, "drop_every_s") { settings.dropEvery = every }
        if let length = try seconds(params, "drop_for_s") { settings.dropFor = length }
        if let cuts = params["drop_cuts"] as? Bool { settings.dropCuts = cuts }
        guard settings.dropEvery == .zero || settings.dropFor < settings.dropEvery else {
            throw HookError(message: "drop_for_s must be shorter than drop_every_s")
        }
        SupermuxDeviceLoopbackImpairment.configure(settings)
        if let now = try seconds(params, "drop_now_s"), now > .zero {
            SupermuxDeviceLoopbackImpairment.dropNow(for: now)
        }
        return payload(SupermuxDeviceLoopbackImpairment.status())
    }

    private static func payload(_ status: SupermuxDeviceLoopbackImpairment.Status) -> [String: Any] {
        func direction(_ stats: SupermuxDeviceLoopbackImpairment.DirectionStats) -> [String: Any] {
            [
                "delivered_bytes": stats.deliveredBytes,
                "queued_bytes": stats.queuedBytes,
                "peak_queued_bytes": stats.peakQueuedBytes,
                "writes_waited": stats.writesWaited,
            ]
        }
        let toHost = milliseconds(of: SupermuxDeviceLoopbackLatency.toHost)
        let toViewer = milliseconds(of: SupermuxDeviceLoopbackLatency.toViewer)
        return [
            "to_host_ms": toHost,
            "to_viewer_ms": toViewer,
            "rtt_ms": toHost + toViewer,
            "bytes_per_second": status.settings.bytesPerSecond,
            "queue_bytes": status.settings.queueBytes,
            "drop_every_s": seconds(of: status.settings.dropEvery),
            "drop_for_s": seconds(of: status.settings.dropFor),
            "drop_cuts": status.settings.dropCuts,
            "drop_ends_in_ms": status.dropEndsIn.map(milliseconds(of:)) ?? NSNull(),
            "drops_started": status.dropsStarted,
            "connections_cut": status.connectionsCut,
            "live_connections": status.liveConnections,
            "to_host": direction(status.toHost),
            "to_viewer": direction(status.toViewer),
        ]
    }

    private static func number(_ params: [String: Any], _ key: String) throws -> Double? {
        guard let value = params[key], !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, number.doubleValue >= 0, number.doubleValue.isFinite else {
            throw HookError(message: "\(key) must be a number of at least 0")
        }
        return number.doubleValue
    }

    private static func integer(_ params: [String: Any], _ key: String) throws -> Int? {
        try number(params, key).map { Int(min($0, 1e12)) }
    }

    private static func milliseconds(_ params: [String: Any], _ key: String) throws -> Duration? {
        try number(params, key).map { .milliseconds(Int(min($0, 10_000))) }
    }

    private static func seconds(_ params: [String: Any], _ key: String) throws -> Duration? {
        try number(params, key).map { .milliseconds(Int(min($0, 3600) * 1000)) }
    }

    private static func milliseconds(of duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
    }

    private static func seconds(of duration: Duration) -> Double {
        Double(milliseconds(of: duration)) / 1000
    }
}
#endif
