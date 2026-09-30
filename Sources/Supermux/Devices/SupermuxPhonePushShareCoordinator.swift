import CmuxSurfaceCatalogModel
import Foundation
import OSLog
import SupermuxKit
import SupermuxMobileCore

private let shareCoordinatorLog = Logger(subsystem: "dev.supermux", category: "phone-push-share")

/// Provisions the direct-APNs lane of the user's other Macs: whenever a
/// device link connects, this Mac offers its provider identity (only to a
/// Mac that has none) and its known phone registrations (merged there without
/// overwriting). The unattended MacBook where agents run can then push to the
/// phone even if the phone never focused it (DESIGN.md decision 8).
///
/// Gated by `supermux.devices.sharePush` here and on the peer, and by the
/// peer's `supermux.phone_push_share.v1` capability. The link is an
/// authenticated same-account Mac-to-Mac session; the receiving host accepts
/// the share only from an admitted Mac peer. Nothing secret is logged.
@MainActor
final class SupermuxPhonePushShareCoordinator {
    /// One outcome, kept for DEBUG introspection (no secrets).
    struct Attempt: Sendable {
        let machine: String
        let result: String
        let sentCredentials: Bool
        let sentRegistrations: Int
        let at: Date
    }

    private let devices: SupermuxDevices
    private let service: SupermuxPhonePushService
    private let settings: SupermuxDevicesSettings
    private var eventsTask: Task<Void, Never>?
    private var inFlight: Set<String> = []
    private(set) var attempts: [Attempt] = []

    init(devices: SupermuxDevices, service: SupermuxPhonePushService, settings: SupermuxDevicesSettings) {
        self.devices = devices
        self.service = service
        self.settings = settings
    }

    /// Starts listening for link connections. Later calls are no-ops.
    func start() {
        guard eventsTask == nil else { return }
        let stream = devices.events()
        eventsTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard case .linkConnected(let machine) = event else { continue }
                await self?.share(with: machine)
            }
        }
    }

    /// Offers this Mac's push state to one connected device.
    @discardableResult
    func share(with machine: SurfaceMachineID) async -> String {
        let key = machine.rawValue
        guard !inFlight.contains(key) else { return "in_flight" }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        let outcome = await performShare(with: machine)
        record(machine: key, outcome)
        return outcome.result
    }

    private struct Outcome {
        var result: String
        var sentCredentials = false
        var sentRegistrations = 0
    }

    private func performShare(with machine: SurfaceMachineID) async -> Outcome {
        guard settings.sharePush else { return Outcome(result: "skip_share_disabled") }
        let local = await service.shareSnapshot()
        guard local.credentials != nil || !local.registrations.isEmpty else {
            return Outcome(result: "skip_nothing_to_share")
        }
        guard await devices.supports(.phonePushShareV1, on: machine) else {
            return Outcome(result: "skip_peer_unsupported")
        }
        let peer: SupermuxPhonePushStatus
        do {
            peer = try await devices.request(
                SupermuxMobileMethod.phonePushStatus.rawValue,
                on: machine,
                as: SupermuxPhonePushStatus.self
            )
        } catch {
            return Outcome(result: "status_failed")
        }
        guard let plan = SupermuxPhonePushSharePlanner.plan(
            local: local.credentials,
            localRegistrations: local.registrations,
            peer: peer,
            shareEnabled: settings.sharePush
        ) else {
            return Outcome(result: "skip_peer_up_to_date")
        }
        var outcome = Outcome(
            result: "shared",
            sentCredentials: plan.credentials != nil,
            sentRegistrations: plan.registrations.count
        )
        do {
            let reply = try await devices.request(.phonePushShare, params: plan.wireParams, on: machine)
            outcome.result = "shared:" + ((reply["credentials"] as? String) ?? "unknown")
        } catch let error as SupermuxDeviceError {
            outcome.result = "share_failed:" + error.code
        } catch {
            outcome.result = "share_failed"
        }
        return outcome
    }

    private func record(machine: String, _ outcome: Outcome) {
        shareCoordinatorLog.info(
            "phone push share result=\(outcome.result, privacy: .public) credentials=\(outcome.sentCredentials) registrations=\(outcome.sentRegistrations)"
        )
        attempts.append(Attempt(
            machine: machine,
            result: outcome.result,
            sentCredentials: outcome.sentCredentials,
            sentRegistrations: outcome.sentRegistrations,
            at: Date()
        ))
        if attempts.count > 50 { attempts.removeFirst(attempts.count - 50) }
    }
}
