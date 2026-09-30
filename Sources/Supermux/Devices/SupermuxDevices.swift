import CMUXMobileCore
import CmuxSurfaceCatalogModel
import Foundation
import Observation
import SupermuxKit

/// The fork's one view of remote Macs ("devices"): which are known, their
/// link state, their synced workspace records (with every `supermux_*`
/// field), generic RPC to their mobile host, their host capabilities, and
/// `supermux.*` event delivery.
///
/// Discovers every `.device` machine registered in the catalog whose provider
/// is a `DeviceSurfaceProvider` — real Macs and the DEBUG loopback device
/// alike — so nothing here changes when a new kind of device provider appears.
///
/// Observation: `devices` changes only when the list or a device's state
/// changes; `revision` bumps (at most once per main-runloop turn) on every
/// `SurfaceCatalog` change, link (re)connect or loss, and `supermux.*` event,
/// so coordinators can re-reconcile. ``events()`` streams per-device events.
///
/// ```swift
/// let devices = SupermuxComposition.devices
/// for device in devices.devices where device.hasFetchedRecords {
///     let records = devices.records(on: device.machine)
/// }
/// ```
@MainActor
@Observable
final class SupermuxDevices {
    /// Every known remote Mac, loopback last, then by name.
    private(set) var devices: [SupermuxDevice] = []
    /// Bumps on any catalog change, link edge, or `supermux.*` event.
    private(set) var revision: UInt64 = 0

    @ObservationIgnored let catalog: SurfaceCatalog
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var catalogObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var loopbackInstances: Set<SurfaceDeviceInstanceID> = []
    /// Links whose post-connect record fetch finished since they last connected.
    @ObservationIgnored var fetchedInstances: Set<SurfaceDeviceInstanceID> = []
    /// Host capabilities per link connection (cleared on every link edge).
    @ObservationIgnored var capabilitiesByInstance: [SurfaceDeviceInstanceID: Set<String>] = [:]
    @ObservationIgnored var capabilityTasks: [SurfaceDeviceInstanceID: Task<Set<String>?, Never>] = [:]
    @ObservationIgnored var eventContinuations: [UUID: AsyncStream<SupermuxDeviceEvent>.Continuation] = [:]

    init(catalog: SurfaceCatalog, notificationCenter: NotificationCenter = .default) {
        self.catalog = catalog
        self.notificationCenter = notificationCenter
    }

    /// Starts following the catalog. Idempotent.
    func start() {
        guard catalogObserver == nil else { return }
        catalogObserver = notificationCenter.addObserver(
            forName: SurfaceCatalog.didChangeNotification,
            object: catalog,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        refreshNow()
    }

    // MARK: - Lookup

    /// The known device for a machine.
    func device(for machine: SurfaceMachineID) -> SupermuxDevice? {
        devices.first { $0.machine == machine } ?? computeDevice(machine)
    }

    /// The upstream provider behind a device machine.
    func provider(for machine: SurfaceMachineID) -> DeviceSurfaceProvider? {
        guard machine.isDevice else { return nil }
        return catalog.provider(for: machine) as? DeviceSurfaceProvider
    }

    /// The device's synced workspace records in host order (empty when unknown).
    func records(on machine: SurfaceMachineID) -> [WorkspaceSyncRecord] {
        provider(for: machine)?.link.mirror.workspaces.orderedRecords ?? []
    }

    /// One remote workspace's synced record, matched case-insensitively.
    func record(for ref: SupermuxRemoteWorkspaceRef) -> WorkspaceSyncRecord? {
        records(on: ref.machine).first {
            SupermuxRemoteWorkspaceRef.canonicalWorkspaceID($0.id) == ref.workspaceID
        }
    }

    /// Marks a device as the DEBUG loopback device (its provider registers it).
    func registerLoopback(_ instance: SurfaceDeviceInstanceID) {
        guard loopbackInstances.insert(instance).inserted else { return }
        scheduleRefresh()
    }

    /// Clears the loopback mark.
    func unregisterLoopback(_ instance: SurfaceDeviceInstanceID) {
        guard loopbackInstances.remove(instance) != nil else { return }
        scheduleRefresh()
    }

    // MARK: - Refresh

    /// Coalesces bursts into one refresh on the next main-actor turn.
    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.refreshNow()
        }
    }

    private func refreshNow() {
        let next = catalog.machines.keys
            .compactMap(computeDevice)
            .sorted(by: Self.displayOrder)
        if next != devices { devices = next }
        revision &+= 1
    }

    private func computeDevice(_ machine: SurfaceMachineID) -> SupermuxDevice? {
        guard let instance = machine.deviceInstance, let provider = provider(for: machine) else { return nil }
        let link = provider.link
        let info = catalog.machines[machine]
        if !link.isConnected { fetchedInstances.remove(instance) }
        let state: SupermuxDeviceLinkState
        if link.isConnected {
            state = .connected
        } else if info?.linkState == .connecting {
            state = .connecting
        } else {
            state = .offline
        }
        return SupermuxDevice(
            machine: machine,
            instance: instance,
            displayName: info?.name ?? provider.record.displayName,
            linkState: state,
            linkDetail: info?.linkError,
            hasFetchedRecords: link.isConnected && fetchedInstances.contains(instance) && link.mirror.workspaces.hasState,
            isLoopback: loopbackInstances.contains(instance)
        )
    }

    private static func displayOrder(_ lhs: SupermuxDevice, _ rhs: SupermuxDevice) -> Bool {
        if lhs.isLoopback != rhs.isLoopback { return !lhs.isLoopback }
        let byName = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhs.id < rhs.id
    }
}
