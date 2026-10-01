import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// The fork's hook into upstream `DeviceLink` (touchpoint
/// `device-link-supermux-events`, SUPERMUX-TOUCHPOINTS.md #517): the extra
/// topics every link subscribes to, and the three signals the link forwards.
/// Below it, the link's busy-host retry (`device-link-busy-retry`, #721).
/// Everything lands on ``SupermuxDevices`` (``SupermuxComposition/devices``).
@MainActor
enum SupermuxDeviceLinkEvents {
    /// The `supermux.*` topics each device link subscribes to, on top of
    /// upstream's `DeviceLink.eventTopics`. The host accepts any topic set.
    nonisolated static let topics: Set<String> = Set(SupermuxMobileTopic.allCases.map(\.rawValue))

    /// A `supermux.*` envelope arrived on the link for `instance`.
    static func receive(instance: SurfaceDeviceInstanceID, topic: String, payload: Data?) {
        SupermuxComposition.devices.receive(topic: topic, payload: payload, from: instance)
    }

    /// The link (re)connected and its post-connect `mobile.sync.fetch` ran.
    static func linkConnected(instance: SurfaceDeviceInstanceID) {
        SupermuxComposition.devices.linkDidConnect(instance)
    }

    /// The link was live and is now gone.
    static func linkLost(instance: SurfaceDeviceInstanceID) {
        SupermuxComposition.devices.linkDidDisconnect(instance)
    }
}

// MARK: - Busy hosts (touchpoint `device-link-busy-retry`)

extension DeviceLink {
    /// The waits before asking a busy host again (about 8 s in all).
    static let supermuxBusyRetryDelays: [Duration] = [
        .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2), .seconds(4),
    ]

    /// Runs one request, asking again while the other Mac's host answers
    /// `server_busy`. The host gives that answer when its per-connection
    /// request quota is full (16 at a time), without running the request, so
    /// asking again is safe for every method; a reconnect fills it at once,
    /// because every mirrored terminal re-attaches (replays, viewports) while
    /// the capability request and held tab closes go out. Taking the refusal
    /// as the answer left a connection without its capabilities (typing fell
    /// back to upstream's text path) and brought a tab closed offline back.
    /// The phone treats the same answer as transient. Only the connection the
    /// request started on is asked again (`isCurrent`; a reconnect cancels
    /// it, as upstream cancels a request whose connection went), a cancelled
    /// caller ends the wait, and once the waits run out the refusal is the
    /// answer.
    func supermuxAskingAgainWhileBusy(
        isCurrent: () -> Bool,
        _ send: () async throws -> Data
    ) async throws -> Data {
        var delays = Self.supermuxBusyRetryDelays[...]
        while true {
            do {
                return try await send()
            } catch DeviceLinkError.hostRejected(let code, let message) where code == "server_busy" {
                guard let delay = delays.popFirst() else {
                    throw DeviceLinkError.hostRejected(code: code, message: message)
                }
                #if DEBUG
                cmuxDebugLog("supermux.deviceLink host busy, asking again in \(delay)")
                #endif
                try await Task.sleep(for: delay)
                guard isCurrent() else { throw CancellationError() }
            }
        }
    }
}
