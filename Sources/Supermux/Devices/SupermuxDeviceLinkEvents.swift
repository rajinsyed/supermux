import CmuxMobileRPC
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// The fork's hook into upstream `DeviceLink` (touchpoint
/// `device-link-supermux-events`, SUPERMUX-TOUCHPOINTS.md #517): the extra
/// topics every link subscribes to, and the three signals the link forwards.
/// Below it, the link's busy-host retry (`device-link-busy-retry`, #721) and
/// its answer to a missed reply deadline (`device-link-slow-request`, #723).
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

// MARK: - Missed deadlines (touchpoint `device-link-slow-request`)

extension SupermuxDeviceLinkEvents {
    /// The `hostRejected` code of a request whose reply missed its deadline
    /// while the other Mac still answers. The work may still run there.
    nonisolated static let missedDeadlineCode = "timed_out"

    /// Whether `error` is a missed reply deadline on a link that stays up
    /// (``DeviceLink/supermuxMissedDeadline(_:_:client:isCurrent:)``).
    nonisolated static func isMissedDeadline(_ error: any Error) -> Bool {
        guard case let .hostRejected(code, _)? = error as? DeviceLinkError else { return false }
        return code == missedDeadlineCode
    }
}

extension DeviceLink {
    /// How long the liveness check after a missed deadline waits for the other Mac.
    static let supermuxLivenessTimeoutNanoseconds: UInt64 = 10_000_000_000

    /// What a request whose reply missed its deadline throws. Upstream took
    /// every missed deadline as a dead transport and redialed, which drops
    /// every mirror, Files panel and held close of that Mac for the
    /// reconnect's backoff, and the reconnect sends the same slow call again:
    /// a `projects.list` waiting on git in project folders behind an
    /// unanswered macOS privacy prompt took the link down every ~20 s. So the
    /// link first asks the other Mac whether it still answers
    /// (`mobile.events.probe`): any answer, a refusal included, keeps the link
    /// and fails only this request (`timed_out`); no answer within 10 s is a
    /// dead link, which reconnects as upstream does. On an Iroh route the
    /// other Mac's connection answers the probe without its main thread, so a
    /// Mac whose main thread is stuck still counts as alive; on a Tailscale
    /// route its authorization runs on that main thread, so a Mac stuck there
    /// for 10 s still reads as lost and redials, as upstream did.
    /// `isCurrent` says the request's connection is still the link's;
    /// `method` names the request in the log.
    func supermuxMissedDeadline(
        _ method: String,
        _ error: MobileShellConnectionError,
        client: MobileCoreRPCClient,
        isCurrent: () -> Bool
    ) async -> any Error {
        let answers = await Self.supermuxHostAnswers(client)
        guard isCurrent() else { return CancellationError() }
        guard answers else {
            reportTransportLost(error)
            return DeviceLinkError.notConnected
        }
        #if DEBUG
        cmuxDebugLog("supermux.deviceLink \(method) missed its reply deadline; the host still answers, so the link stays")
        #endif
        let name = record.deviceName
        return DeviceLinkError.hostRejected(
            code: SupermuxDeviceLinkEvents.missedDeadlineCode,
            message: String(
                localized: "supermux.devices.error.replyTimedOut",
                defaultValue: "\(name) did not answer in time. It is still connected; try again."
            )
        )
    }

    /// Whether the other Mac's connection answers a probe in time. The probe
    /// carries no `client_id`: the host records one on its main thread before
    /// answering (the link's own was recorded on this connection when it
    /// connected), and this probe must not wait on that thread.
    private static func supermuxHostAnswers(_ client: MobileCoreRPCClient) async -> Bool {
        do {
            let probe = try MobileCoreRPCClient.requestData(method: "mobile.events.probe", params: [
                "stream_id": "supermux-liveness",
            ])
            #if DEBUG
            SupermuxDeviceLoopbackHostAcceptor.blockMainDuringLivenessProbeIfArmed()
            #endif
            _ = try await client.sendRequest(probe, timeoutNanoseconds: supermuxLivenessTimeoutNanoseconds)
            return true
        } catch let error as MobileShellConnectionError {
            if case .rpcError = error { return true }
            return false
        } catch {
            return false
        }
    }
}
