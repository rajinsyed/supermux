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
/// `SurfaceCatalog` change of a device machine (or of no machine in
/// particular), link (re)connect or loss, mirror binding change, and
/// `supermux.*` event except the Changes and Files pokes, so coordinators can
/// re-reconcile. Changes of every other machine (this Mac's own panes, Cloud
/// and SSH ones) only bump ``localCatalogRevision``, at most once a second, so
/// local terminal churn never wakes the device followers. ``events()``
/// streams per-device events.
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
    /// Bumps on a device machine's catalog change, link edge, binding change,
    /// or `supermux.*` event (not the Changes and Files pokes).
    private(set) var revision: UInt64 = 0
    /// Bumps at most once a second while any other machine's catalog entries
    /// change (an unbound mirror that got a local pane stops being a mirror).
    private(set) var localCatalogRevision: UInt64 = 0

    /// How long non-device catalog churn is coalesced into one
    /// ``localCatalogRevision`` bump.
    nonisolated static let localChangeCoalescing: Duration = .seconds(1)

    @ObservationIgnored let catalog: SurfaceCatalog
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var catalogObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var localChangePending = false
    @ObservationIgnored private var recordsCache: [SurfaceMachineID: RecordsSnapshot] = [:]
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
        ) { [weak self] note in
            let machines = note.userInfo?["machines"] as? [String]
            MainActor.assumeIsolated { self?.catalogDidChange(machines: machines) }
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
        recordsSnapshot(on: machine)?.ordered ?? []
    }

    /// One remote workspace's synced record, matched case-insensitively.
    func record(for ref: SupermuxRemoteWorkspaceRef) -> WorkspaceSyncRecord? {
        recordsSnapshot(on: ref.machine)?.byWorkspaceID[ref.workspaceID]
    }

    /// Where the device's synced records stand (nil when unknown): an
    /// unchanged stamp means unchanged records.
    func recordsStamp(on machine: SurfaceMachineID) -> RecordsStamp? {
        recordsSnapshot(on: machine)?.stamp
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
        let machines = Set(next.map(\.machine))
        recordsCache = recordsCache.filter { machines.contains($0.key) }
        revision &+= 1
    }

    /// A catalog change. One naming a device machine, or no machine at all,
    /// refreshes the devices; any other machine's change only feeds
    /// ``localCatalogRevision``.
    private func catalogDidChange(machines: [String]?) {
        guard let machines else {
            scheduleRefresh()
            return
        }
        let isDevice = machines.map { SurfaceMachineID(rawValue: $0).isDevice }
        if isDevice.contains(true) { scheduleRefresh() }
        if isDevice.contains(false) { noteLocalCatalogChange() }
    }

    /// Coalesces non-device catalog churn into one ``localCatalogRevision``
    /// bump per ``localChangeCoalescing`` (a window, not a trailing debounce,
    /// so a Mac whose terminals never stop changing still gets the bump).
    private func noteLocalCatalogChange() {
        guard !localChangePending else { return }
        localChangePending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.localChangeCoalescing)
            guard let self else { return }
            self.localChangePending = false
            self.localCatalogRevision &+= 1
        }
    }

    // MARK: - Records

    /// Identifies one device's synced records as they stand. The sync mirror
    /// replaces its records only together with a new epoch or revision.
    struct RecordsStamp: Equatable {
        let mirror: ObjectIdentifier
        let epoch: String?
        let rev: UInt64
    }

    /// One device's records, sorted and indexed once per stamp.
    private struct RecordsSnapshot {
        /// Held so its identity (the stamp's `mirror`) is never reused while cached.
        let source: MobileSyncCollectionMirror<WorkspaceSyncRecord>
        let stamp: RecordsStamp
        let ordered: [WorkspaceSyncRecord]
        /// By canonical workspace id; the first in host order wins.
        let byWorkspaceID: [String: WorkspaceSyncRecord]
    }

    /// The device's records, re-sorted only when its sync mirror moved on.
    private func recordsSnapshot(on machine: SurfaceMachineID) -> RecordsSnapshot? {
        guard let mirror = provider(for: machine)?.link.mirror.workspaces else { return nil }
        let stamp = RecordsStamp(mirror: ObjectIdentifier(mirror), epoch: mirror.epoch, rev: mirror.rev)
        if let cached = recordsCache[machine], cached.stamp == stamp { return cached }
        let ordered = mirror.orderedRecords
        let snapshot = RecordsSnapshot(
            source: mirror,
            stamp: stamp,
            ordered: ordered,
            byWorkspaceID: Dictionary(
                ordered.map { (SupermuxRemoteWorkspaceRef.canonicalWorkspaceID($0.id), $0) },
                uniquingKeysWith: { first, _ in first }
            )
        )
        recordsCache[machine] = snapshot
        return snapshot
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
