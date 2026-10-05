import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// Asks each connected Mac for its direct addresses
/// (`mobile.supermux.route.candidates`) and keeps them in
/// ``SupermuxComposition/routeCandidateStore``, where the dialer reads them
/// (``SupermuxRouteDialCandidates``): once per link connection, then every
/// ``refreshInterval`` while it stays up. A failed ask is tried again after
/// ``retryInterval``.
///
/// The addresses are filed under the endpoint the outgoing session actually
/// reached (its TLS-verified id), never only under the id the answer claims.
@MainActor
final class SupermuxRouteCandidateSync {
    /// How often a connected Mac is asked again.
    static let refreshInterval: TimeInterval = 600
    /// How long after a failed ask the next one may go.
    static let retryInterval: TimeInterval = 60

    /// What one ask did, for the DEBUG driver and the journal.
    enum Outcome: String {
        case stored, unsupported, failed, noEndpoint = "no_endpoint", endpointMismatch = "endpoint_mismatch"
    }

    private struct State {
        var attemptedAt: Date?
        var storedAt: Date?
        var inFlight = false
    }

    private let devices: SupermuxDevices
    private let store: SupermuxRouteCandidateStore
    private let sessionEndpointID: @MainActor (SurfaceDeviceInstanceID) async -> String?
    private var states: [SurfaceDeviceInstanceID: State] = [:]
    /// Asks that stored addresses, since launch (DEBUG driver).
    private(set) var storedCount = 0

    init(
        devices: SupermuxDevices,
        store: SupermuxRouteCandidateStore,
        sessionEndpointID: @escaping @MainActor (SurfaceDeviceInstanceID) async -> String?
    ) {
        self.devices = devices
        self.store = store
        self.sessionEndpointID = sessionEndpointID
    }

    /// A link (re)connected: ask it now.
    func linkConnected(_ device: SupermuxDevice) {
        states[device.instance] = State()
        startIfDue(device, now: Date())
    }

    /// A link went away: its next connection asks again at once.
    func linkLost(_ instance: SurfaceDeviceInstanceID) {
        states[instance] = nil
    }

    /// Asks every connected Mac whose addresses are due.
    func tick(connected: [SupermuxDevice], now: Date = Date()) {
        let live = Set(connected.map(\.instance))
        states = states.filter { live.contains($0.key) }
        for device in connected { startIfDue(device, now: now) }
    }

    private func startIfDue(_ device: SupermuxDevice, now: Date) {
        let state = states[device.instance] ?? State()
        guard !state.inFlight else { return }
        if let storedAt = state.storedAt, now.timeIntervalSince(storedAt) < Self.refreshInterval { return }
        if let attemptedAt = state.attemptedAt, now.timeIntervalSince(attemptedAt) < Self.retryInterval { return }
        Task { _ = await fetch(device) }
    }

    /// Asks one Mac now and stores its answer.
    @discardableResult
    func fetch(_ device: SupermuxDevice) async -> Outcome {
        let instance = device.instance
        states[instance, default: State()].inFlight = true
        states[instance]?.attemptedAt = Date()
        let outcome = await ask(device)
        states[instance]?.inFlight = false
        if outcome == .stored {
            states[instance]?.storedAt = Date()
            storedCount += 1
        }
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
        } catch {
            return .failed
        }
        let claimed = answer.endpointID?.lowercased()
        let reached = await sessionEndpointID(device.instance)?.lowercased()
        // The loopback device has no Iroh session; its answer's own id stands in.
        guard let endpointID = reached ?? (device.isLoopback ? claimed : nil) else { return .noEndpoint }
        if let claimed, claimed != endpointID { return .endpointMismatch }
        let key = SupermuxRoutePeerKey(deviceID: device.instance.deviceID, tag: device.instance.tag, endpointID: endpointID)
        await store.recordFetched(answer.addresses, for: key)
        return .stored
    }
}
