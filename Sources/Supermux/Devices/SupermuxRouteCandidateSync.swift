import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// Asks each connected Mac for its direct addresses
/// (`mobile.supermux.route.candidates`) and keeps them in
/// ``SupermuxComposition/routeCandidateStore``, where the dialer reads them
/// (``SupermuxRouteDialCandidates``), on the schedule the phone shares
/// (``SupermuxRouteCandidateFetchSchedule``): at once on each link
/// connection, again 10 min after an answer that settled it and 1 min after
/// one that did not (a host with no address yet, an empty list, a failure),
/// whose addresses stay as they were.
///
/// The addresses are filed under the endpoint the outgoing session actually
/// reached (its TLS-verified id), never only under the id the answer claims.
/// A host that turned direct off has its addresses forgotten. New addresses
/// tell the route switcher, so a relayed link probes them at once.
@MainActor
final class SupermuxRouteCandidateSync {
    /// What one ask did, for the DEBUG driver and the journal.
    enum Outcome: String {
        case stored, empty, unsupported, failed
        case notReady = "not_ready"
        case directOff = "direct_off"
        case noEndpoint = "no_endpoint"
        case endpointMismatch = "endpoint_mismatch"

        /// The answer as the shared schedule reads it.
        var answer: SupermuxRouteCandidateFetchSchedule.Answer {
            switch self {
            case .stored: .stored
            case .empty: .empty
            case .notReady: .notReady
            case .directOff: .directOff
            case .unsupported: .unsupported
            case .failed, .noEndpoint, .endpointMismatch: .failed
            }
        }
    }

    private let devices: SupermuxDevices
    private let store: SupermuxRouteCandidateStore
    private let sessionEndpointID: @MainActor (SurfaceDeviceInstanceID) async -> String?
    private let candidatesChanged: @MainActor (SurfaceDeviceInstanceID) -> Void
    private var schedules: [SurfaceDeviceInstanceID: SupermuxRouteCandidateFetchSchedule] = [:]
    /// Asks that stored addresses, since launch (DEBUG driver).
    private(set) var storedCount = 0

    init(
        devices: SupermuxDevices,
        store: SupermuxRouteCandidateStore,
        sessionEndpointID: @escaping @MainActor (SurfaceDeviceInstanceID) async -> String?,
        candidatesChanged: @escaping @MainActor (SurfaceDeviceInstanceID) -> Void
    ) {
        self.devices = devices
        self.store = store
        self.sessionEndpointID = sessionEndpointID
        self.candidatesChanged = candidatesChanged
    }

    /// A link (re)connected: ask it now.
    func linkConnected(_ device: SupermuxDevice) {
        schedules[device.instance, default: SupermuxRouteCandidateFetchSchedule()].connected()
        startIfDue(device, now: Date())
    }

    /// A link went away: its next connection asks again at once.
    func linkLost(_ instance: SurfaceDeviceInstanceID) {
        schedules[instance] = nil
    }

    /// Asks every connected Mac whose addresses are due.
    func tick(connected: [SupermuxDevice], now: Date = Date()) {
        let live = Set(connected.map(\.instance))
        schedules = schedules.filter { live.contains($0.key) }
        for device in connected { startIfDue(device, now: now) }
    }

    private func startIfDue(_ device: SupermuxDevice, now: Date) {
        guard schedules[device.instance, default: SupermuxRouteCandidateFetchSchedule()].isDue(at: now) else { return }
        Task { _ = await fetch(device) }
    }

    /// Asks one Mac now and stores its answer.
    @discardableResult
    func fetch(_ device: SupermuxDevice) async -> Outcome {
        let instance = device.instance
        schedules[instance, default: SupermuxRouteCandidateFetchSchedule()].started(at: Date())
        let outcome = await ask(device)
        schedules[instance]?.finished(outcome.answer, at: Date())
        if outcome == .stored { storedCount += 1 }
        if outcome != .stored, outcome != .unsupported {
            cmuxDebugLog("supermux.route candidates from \(instance.deviceID.prefix(8)): \(outcome.rawValue)")
        }
        return outcome
    }

    private func ask(_ device: SupermuxDevice) async -> Outcome {
        guard await devices.supports(.routeCandidatesV1, on: device.machine) else { return .unsupported }
        let answer: SupermuxRouteCandidatesDTO
        do {
            answer = try await devices.request(
                SupermuxMobileMethod.routeCandidates.rawValue, on: device.machine, as: SupermuxRouteCandidatesDTO.self)
        } catch SupermuxDeviceError.hostRejected(let code, _) {
            switch SupermuxRouteCandidateFetchSchedule.Answer(errorCode: code) {
            case .notReady: return .notReady
            case .directOff:
                await forget(device.instance)
                return .directOff
            default: return .failed
            }
        } catch {
            return .failed
        }
        let claimed = answer.endpointID?.lowercased()
        let reached = await sessionEndpointID(device.instance)?.lowercased()
        // The loopback device has no Iroh session; its answer's own id stands in.
        guard let endpointID = reached ?? (device.isLoopback ? claimed : nil) else { return .noEndpoint }
        if let claimed, claimed != endpointID { return .endpointMismatch }
        let key = SupermuxRoutePeerKey(deviceID: device.instance.deviceID, tag: device.instance.tag, endpointID: endpointID)
        let before = await store.dialAddresses(for: key)
        guard await store.recordFetched(answer.addresses, for: key) else { return .empty }
        if await store.dialAddresses(for: key) != before { candidatesChanged(device.instance) }
        return .stored
    }

    /// Forgets every cached endpoint of that Mac (it turned direct off).
    private func forget(_ instance: SurfaceDeviceInstanceID) async {
        for peer in await store.peers()
        where peer.key.deviceID == instance.deviceID.lowercased() && peer.key.tag == instance.tag {
            await store.forget(peer.key)
        }
    }
}
