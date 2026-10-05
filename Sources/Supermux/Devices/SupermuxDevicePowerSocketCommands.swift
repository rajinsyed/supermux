#if DEBUG
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// DEBUG-only `supermux.devices.power.*` drivers for
/// `tests/supermux/loopback_device_sleep_wake_e2e.py`, routed from
/// ``SupermuxDevicesSocketCommands``. A test cannot put macOS to sleep, so
/// these run the app's own handlers for the system's signals
/// (``SupermuxSystemPower``, ``SupermuxDeviceSleepCourtesy``).
///
/// - `power.simulate {event: will_sleep|did_wake|screens_did_wake|network_change,
///   slept_s?, announce?}`: `will_sleep` (by default without the notice, so the
///   loopback link does not hear its own host, and without the display check);
///   a wake `slept_s` after the simulated willSleep; a network change after its
///   debounce. Waits for the recovery it starts → the status below.
/// - `power.announce_sleep {}`: only the notice, from this host to the Macs
///   subscribed to it → `{}`.
/// - `power.peer_dialed_in {machine}`: what an admitted session from that Mac
///   runs → `{}`.
/// - `power.status {machine?}` → `{dark, recoveries, last_recovery: {reason,
///   slept_s, rebuilds_main, main, lane_rebuilt, redialed, probed_now},
///   activity: {held, inbound, outbound}, peer: {asleep, wait_ms}}`.
/// - `power.reset {}`: awake, no recoveries, no notices → the status.
@MainActor
enum SupermuxDevicePowerSocketCommands {
    static let methodPrefix = "power."

    struct HookError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func handles<S: StringProtocol>(_ name: S) -> Bool {
        name.hasPrefix(methodPrefix)
    }

    static func handle<S: StringProtocol>(_ name: S, _ params: [String: Any]) async throws -> [String: Any] {
        let power = SupermuxComposition.systemPower
        let courtesy = SupermuxComposition.sleepCourtesy
        switch String(name.dropFirst(methodPrefix.count)) {
        case "simulate":
            try await simulate(params)
        case "announce_sleep":
            courtesy.announce()
            return [:]
        case "peer_dialed_in":
            courtesy.peerDialedIn(try instance(params))
            return [:]
        case "status":
            break
        case "reset":
            power.reset()
            courtesy.reset()
        default:
            throw HookError(message: "unknown power method \(name)")
        }
        return status(machine: try? instance(params))
    }

    private static func simulate(_ params: [String: Any]) async throws {
        let power = SupermuxComposition.systemPower
        switch params["event"] as? String {
        case "will_sleep":
            power.willSleep(announce: params["announce"] as? Bool ?? false, checksDisplay: false)
        case "did_wake":
            await power.woke(.wake, at: wakeTime(params))?.value
        case "screens_did_wake":
            await power.woke(.screensWake, at: wakeTime(params))?.value
        case "network_change":
            await power.networkChanged().value
        default:
            throw HookError(message: "event must be will_sleep, did_wake, screens_did_wake or network_change")
        }
    }

    /// `slept_s` after the simulated willSleep, else now.
    private static func wakeTime(_ params: [String: Any]) -> Date {
        guard let slept = (params["slept_s"] as? NSNumber)?.doubleValue,
              let since = SupermuxComposition.systemPower.asleepSince else { return Date() }
        return since.addingTimeInterval(slept)
    }

    private static func status(machine instance: SurfaceDeviceInstanceID?) -> [String: Any] {
        let power = SupermuxComposition.systemPower
        let activity = SupermuxComposition.remoteSessionActivity
        activity.update()
        var result: [String: Any] = [
            "dark": power.isDark,
            "recoveries": power.recoveries,
            "activity": ["held": activity.isHeld, "inbound": activity.inbound, "outbound": activity.outbound],
        ]
        if let last = power.lastRecovery {
            result["last_recovery"] = [
                "reason": last.recovery.reason.rawValue,
                "slept_s": last.recovery.sleptSeconds ?? NSNull(),
                "rebuilds_main": last.recovery.rebuildsMainEndpoint,
                "main": last.main,
                "lane_rebuilt": last.laneRebuilt,
                "redialed": last.redialed,
                "probed_now": true,
            ] as [String: Any]
        }
        if let instance {
            let courtesy = SupermuxComposition.sleepCourtesy
            let wait = courtesy.redialWait(for: instance, after: .zero)
            result["peer"] = [
                "asleep": courtesy.isAsleep(instance),
                "wait_ms": wait.components.seconds * 1_000 + wait.components.attoseconds / 1_000_000_000_000_000,
            ] as [String: Any]
        }
        return result
    }

    private static func instance(_ params: [String: Any]) throws -> SurfaceDeviceInstanceID {
        guard let raw = params["machine"] as? String,
              let instance = SurfaceMachineID(rawValue: raw).deviceInstance else {
            throw HookError(message: "machine must be a device id from supermux.devices.list")
        }
        return instance
    }
}
#endif
