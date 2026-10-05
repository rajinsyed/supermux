import CmuxIrxTransport
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// Telling the other Macs this one is going to sleep, and backing off a Mac
/// that said so.
///
/// Before sleeping, this Mac's host sends ``topic`` to every Mac subscribed to
/// it (the links that view it). A link that receives it drops its session at
/// once (it is about to stop answering) and, until that Mac shows it is awake,
/// waits at least ``SupermuxPeerSleep/wait`` (5 min) before each dial instead
/// of its usual seconds-to-two-minutes backoff: a lid-closed laptop was dialed
/// every 40 s all night and woken by many of those dials. When that Mac dials
/// this one (it woke), the waiting link dials it back at once.
///
/// The notice is additive: an older Mac does not subscribe to the topic and
/// never sees it; an older viewer ignores it. Journals (category `power`):
/// `peer-sleeping {device}`, `peer-dialed-in {device, dials_back}`.
@MainActor
final class SupermuxDeviceSleepCourtesy {
    /// The event a host sends to its subscribed Macs before it sleeps.
    nonisolated static let topic = "supermux.device.sleeping"

    private let journal: IrxJournal
    private var peers: [SurfaceDeviceInstanceID: SupermuxPeerSleep] = [:]
    private var events: Task<Void, Never>?

    init(journal: IrxJournal) {
        self.journal = journal
    }

    /// Follows the links' sessions (a long one proves a sleeping Mac awake). Idempotent.
    func start() {
        guard events == nil else { return }
        let stream = SupermuxComposition.devices.events()
        events = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case let .linkConnected(machine):
                    guard let instance = machine.deviceInstance else { continue }
                    peers[instance, default: SupermuxPeerSleep()].connected(at: Date())
                case let .linkLost(machine):
                    guard let instance = machine.deviceInstance else { continue }
                    peers[instance]?.disconnected(at: Date())
                case .topic:
                    continue
                }
            }
        }
    }

    // MARK: - This Mac going to sleep

    /// Tells the Macs viewing this one that it is going to sleep.
    func announce() {
        MobileHostService.emitEvent(topic: Self.topic, payload: ["at_ms": Int(Date().timeIntervalSince1970 * 1_000)])
    }

    // MARK: - Another Mac going to sleep

    /// `instance`'s host said it is going to sleep: drop the link's session
    /// now and wait.
    func received(from instance: SurfaceDeviceInstanceID) {
        peers[instance, default: SupermuxPeerSleep()].announced(at: Date())
        journal.record("power", "peer-sleeping", attributes(instance))
        link(for: instance)?.supermuxPeerGoingToSleep()
    }

    /// The wait before the link to `instance` dials again: `computed`, or
    /// longer while that Mac is asleep.
    func redialWait(for instance: SurfaceDeviceInstanceID, after computed: Duration) -> Duration {
        peers[instance]?.wait(after: computed) ?? computed
    }

    /// Whether `instance` said it is going to sleep and has not shown it is awake.
    func isAsleep(_ instance: SurfaceDeviceInstanceID) -> Bool {
        peers[instance]?.isAsleep ?? false
    }

    /// A Mac's session was admitted on this host: it is awake, so this Mac's
    /// link to it, if it is waiting, dials at once (at most every 15 s).
    func peerDialedIn(endpointIDHex: String, deviceID: String, tag: String) {
        guard let instance = instance(endpointIDHex: endpointIDHex, deviceID: deviceID, tag: tag) else { return }
        peerDialedIn(instance)
    }

    func peerDialedIn(_ instance: SurfaceDeviceInstanceID) {
        let dialsBack = peers[instance, default: SupermuxPeerSleep()].dialedIn(at: Date())
        var fields = attributes(instance)
        fields["dials_back"] = String(dialsBack)
        journal.record("power", "peer-dialed-in", fields)
        guard dialsBack, let link = link(for: instance), case .waiting = link.phase else { return }
        link.refresh()
    }

    // MARK: - Lookup

    private func link(for instance: SurfaceDeviceInstanceID) -> DeviceLink? {
        SupermuxComposition.devices.provider(for: .device(instance))?.link
    }

    /// The device whose Iroh route names `endpointIDHex`, else the one with that device id and tag.
    private func instance(endpointIDHex: String, deviceID: String, tag: String) -> SurfaceDeviceInstanceID? {
        let devices = SupermuxComposition.devices
        let endpoint = endpointIDHex.lowercased()
        for device in devices.devices {
            guard let routes = devices.provider(for: device.machine)?.link.record.routes else { continue }
            for route in routes {
                if case let .peer(identity, _) = route.endpoint, identity.endpointID.lowercased() == endpoint {
                    return device.instance
                }
            }
        }
        return devices.devices.first {
            $0.instance.deviceID.lowercased() == deviceID.lowercased() && $0.instance.tag == tag
        }?.instance
    }

    private func attributes(_ instance: SurfaceDeviceInstanceID) -> [String: String] {
        ["device": String(instance.deviceID.prefix(8)), "tag": instance.tag]
    }

    // MARK: - DEBUG drivers

    /// Forgets every notice (DEBUG drivers).
    func reset() {
        peers = [:]
    }
}
