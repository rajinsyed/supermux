import CmuxSettingsUI
import CmuxSurfaceCatalogModel
import Foundation
import Observation
import SupermuxKit

/// App side of the Settings "Remote Macs" card (`SupermuxRemoteMacsSettingsCard`
/// in `CmuxSettingsUI`): builds the card's snapshot from the device facade,
/// ``SupermuxDevicesSettings``, the "Hide Here" set and the port forwards
/// (``SupermuxPortForwards``), and applies the card's actions. The socket (`supermux.devices.remote_macs_settings*`) drives the
/// same actions, so E2E tests exercise the card's exact write path.
@MainActor
final class SupermuxRemoteMacsSettingsFeed {
    private let devices: SupermuxDevices
    private let settings: SupermuxDevicesSettings
    private let hidden: SupermuxHiddenRemoteWorkspaces
    private let forwards: SupermuxPortForwards

    init(
        devices: SupermuxDevices,
        settings: SupermuxDevicesSettings,
        hidden: SupermuxHiddenRemoteWorkspaces,
        forwards: SupermuxPortForwards
    ) {
        self.devices = devices
        self.settings = settings
        self.hidden = hidden
        self.forwards = forwards
    }

    /// The card's actions.
    func actions() -> SupermuxRemoteMacsSettingsActions {
        SupermuxRemoteMacsSettingsActions(
            updates: { [self] in updates() },
            setAutoMirror: { [self] in setAutoMirror($0) },
            setSyncProjects: { [self] in setSyncProjects($0) },
            setSharePush: { [self] in settings.sharePush = $0 },
            showHiddenWorkspaces: { SupermuxDeviceMirrorsGlue.unhide() },
            setForwardPorts: { [forwards] in forwards.setAutoForward($0) },
            portAction: { [self] in portAction(machineID: $0, remotePort: $1, action: $2) },
            forwardPort: { [self] in forwardPort(machineID: $0) }
        )
    }

    /// A Ports… menu item of one Mac's port (what a mirror row's menu item does).
    func portAction(machineID: String, remotePort: Int, action: SupermuxRemoteMacPortAction) {
        SupermuxMirrorPortsActions.perform(action, machine: SurfaceMachineID(rawValue: machineID), remotePort: remotePort)
    }

    /// Forward a Port… for one Mac.
    func forwardPort(machineID: String) {
        let machine = SurfaceMachineID(rawValue: machineID)
        SupermuxPortForwardPrompt.present(machine: machine, macName: devices.device(for: machine)?.displayName ?? "")
    }

    /// Auto-mirror on/off, applied at once: the coordinator opens (or stops
    /// opening) mirrors in its next pass.
    func setAutoMirror(_ enabled: Bool) {
        settings.autoMirror = enabled
        SupermuxComposition.deviceMirrorCoordinator.scheduleReconcile()
    }

    /// Project sync on/off; turning it on runs a pass now.
    func setSyncProjects(_ enabled: Bool) {
        settings.syncProjects = enabled
        guard enabled else { return }
        Task { await SupermuxComposition.projectSync.syncNow() }
    }

    /// What the card shows now.
    func snapshot() -> SupermuxRemoteMacsSettingsSnapshot {
        SupermuxRemoteMacsSettingsSnapshot(
            autoMirror: settings.autoMirror,
            syncProjects: settings.syncProjects,
            sharePush: settings.sharePush,
            forwardPorts: settings.forwardPorts,
            macs: devices.devices.map { device in
                SupermuxRemoteMacsSettingsSnapshot.Mac(
                    id: device.machine.rawValue,
                    name: device.displayName,
                    link: Self.link(device.linkState),
                    detail: device.linkDetail,
                    workspaceCount: device.hasFetchedRecords ? devices.records(on: device.machine).count : 0,
                    ports: ports(of: device.machine),
                    portsNote: device.isConnected
                        ? SupermuxPortsText.unavailable(forwards.availability[device.machine], macName: device.displayName)
                        : nil
                )
            },
            hiddenWorkspaceCount: hidden.refs.count
        )
    }

    /// One Mac's listed and forwarded ports, by port number, each with the
    /// items its Ports… submenu offers (``SupermuxPortMenuItems``, as on a
    /// mirror row).
    private func ports(of machine: SurfaceMachineID) -> [SupermuxRemoteMacsSettingsSnapshot.Port] {
        let listed = Set((forwards.hostPorts[machine]?.ports ?? []).map(\.port))
        let forwarded = forwards.forwards.values.filter { $0.key.machine == machine }
        let byPort = Dictionary(forwarded.map { ($0.key.remotePort, $0) }, uniquingKeysWith: { first, _ in first })
        return listed.union(byPort.keys).sorted().map { port in
            let forward = byPort[port]
            return SupermuxRemoteMacsSettingsSnapshot.Port(
                remotePort: port,
                localPort: forward?.localPort,
                isForwarded: forward.map { $0.state != .stopped } ?? false,
                lineText: forward.map { SupermuxPortsText.lineItem($0) } ?? ":\(port)",
                menuLabel: SupermuxPortsText.menuLabel(remotePort: port, localPort: forward?.localPort),
                actions: SupermuxPortMenuItems.actions(machine: machine, remotePort: port)
            )
        }
    }

    /// The current snapshot, then one whenever it changes: any device or
    /// record change (`devices.revision`), any port forward change, or any
    /// defaults write (the settings and the hidden set live in `UserDefaults`).
    func updates() -> AsyncStream<SupermuxRemoteMacsSettingsSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SupermuxRemoteMacsSettingsSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let subscription = Subscription(feed: self, continuation: continuation)
        subscription.start()
        continuation.onTermination = { _ in
            Task { @MainActor in subscription.stop() }
        }
        return stream
    }

    /// One `updates()` stream: yields a snapshot only when it changed.
    @MainActor
    private final class Subscription {
        private weak var feed: SupermuxRemoteMacsSettingsFeed?
        private let continuation: AsyncStream<SupermuxRemoteMacsSettingsSnapshot>.Continuation
        private var last: SupermuxRemoteMacsSettingsSnapshot?
        private var observer: (any NSObjectProtocol)?
        private var revisions: Task<Void, Never>?
        private var portChanges: Task<Void, Never>?

        init(feed: SupermuxRemoteMacsSettingsFeed, continuation: AsyncStream<SupermuxRemoteMacsSettingsSnapshot>.Continuation) {
            self.feed = feed
            self.continuation = continuation
        }

        func start() {
            emit()
            revisions = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let devices = self?.feed?.devices else { return }
                    await Self.nextRevision(of: devices)
                    self?.emit()
                }
            }
            portChanges = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let forwards = self?.feed?.forwards else { return }
                    await Self.nextChange(of: forwards)
                    self?.emit()
                }
            }
            observer = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.emit() }
            }
        }

        func stop() {
            revisions?.cancel()
            revisions = nil
            portChanges?.cancel()
            portChanges = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        private func emit() {
            guard let next = feed?.snapshot(), next != last else { return }
            last = next
            continuation.yield(next)
        }

        private static func nextRevision(of devices: SupermuxDevices) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking { _ = devices.revision } onChange: { continuation.resume() }
            }
        }

        private static func nextChange(of forwards: SupermuxPortForwards) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = forwards.forwards
                    _ = forwards.hostPorts
                    _ = forwards.availability
                } onChange: { continuation.resume() }
            }
        }
    }

    private static func link(_ state: SupermuxDeviceLinkState) -> SupermuxRemoteMacsSettingsSnapshot.Mac.Link {
        switch state {
        case .connected: return .connected
        case .connecting: return .connecting
        case .offline: return .offline
        }
    }
}

@MainActor
extension SupermuxComposition {
    /// The Settings "Remote Macs" card's app side.
    static let remoteMacsSettings = SupermuxRemoteMacsSettingsFeed(
        devices: devices,
        settings: devicesSettings,
        hidden: hiddenRemoteWorkspaces,
        forwards: portForwards
    )
}
