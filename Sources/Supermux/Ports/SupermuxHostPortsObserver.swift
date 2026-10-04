import CmuxIrxTransport
import Combine
import Foundation
import Observation
import SupermuxMobileCore

/// Pokes the user's other Macs (`supermux.ports.updated`) when the ports this
/// Mac's workspaces listen on change, so their forwards follow within a moment
/// instead of on the next link connect. They refetch `ports.list` on receipt.
///
/// Watches every main window's workspaces' `listeningPorts` (the sidebar's
/// port detection) and which workspaces there are (not their order), only
/// while a device link subscribes to the topic, so a Mac nobody forwards from
/// pays nothing. Pokes are coalesced into one per ``throttle`` window. It also watches its own terminals' commands: the sidebar
/// scans a terminal only for about 10 s after a command starts, so a server that
/// binds later (a dev script that does other work first) would never be a
/// workspace's port; for a while after a command starts,
/// ``SupermuxLateListenerCheck`` compares the loopback listeners and re-kicks the
/// terminals' port scans when one appears (the attribution that follows pokes).
/// Lives for the app's lifetime (owned by ``SupermuxMobileHostGlue``); the
/// attach/detach pattern is ``SupermuxMobileSidebarStatusObserver``'s.
@MainActor
final class SupermuxHostPortsObserver {
    static let throttle: Duration = .milliseconds(500)
    private static let topic = SupermuxMobileTopic.portsUpdated.rawValue

    private var observers: [any NSObjectProtocol] = []
    private var tabsCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    private var workspaceCancellables: [UUID: AnyCancellable] = [:]
    /// The workspaces seen last; nil while detached, so attaching counts as a change.
    private var lastWorkspaceIDs: Set<UUID>?
    private var pendingPoke: Task<Void, Never>?
    private var commandWatch: Task<Void, Never>?
    private let lateListeners = SupermuxLateListenerCheck()

    init() {
        for name in [Notification.Name.mobileHostEventSubscriptionsDidChange, .mainWindowContextsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileAttachment() }
            })
        }
        reconcileAttachment()
    }

    /// Attaches the per-window pipelines while the topic has a subscriber,
    /// and tears them down when the last one leaves.
    private func reconcileAttachment() {
        guard MobileHostService.hasEventSubscribers(topic: Self.topic) else {
            tabsCancellables.removeAll()
            workspaceCancellables.removeAll()
            lastWorkspaceIDs = nil
            commandWatch?.cancel()
            commandWatch = nil
            lateListeners.stop()
            return
        }
        let managers = SupermuxMobileSidebarStatusObserver.allTabManagers()
        let live = Set(managers.map(ObjectIdentifier.init))
        tabsCancellables = tabsCancellables.filter { live.contains($0.key) }
        for manager in managers where tabsCancellables[ObjectIdentifier(manager)] == nil {
            tabsCancellables[ObjectIdentifier(manager)] = manager.tabsPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshWorkspaceSubscriptions() }
        }
        refreshWorkspaceSubscriptions()
    }

    private func refreshWorkspaceSubscriptions() {
        guard !tabsCancellables.isEmpty else { return }
        let workspaces = SupermuxMobileSidebarStatusObserver.allTabManagers().flatMap(\.tabs)
        let ids = Set(workspaces.map(\.id))
        workspaceCancellables = workspaceCancellables.filter { ids.contains($0.key) }
        for workspace in workspaces where workspaceCancellables[workspace.id] == nil {
            // The first value is the current state, not a change.
            workspaceCancellables[workspace.id] = workspace.$listeningPorts
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] _ in self?.schedulePoke() }
        }
        // A reorder (every agent notification moves its workspace up) changes
        // no ports and no terminals: only a workspace that appears or goes
        // may take ports with it, or bring terminals to watch.
        guard ids != lastWorkspaceIDs else { return }
        lastWorkspaceIDs = ids
        schedulePoke()
        watchCommands()
    }

    /// Follows which of this Mac's own terminals run a command (their shell
    /// integration's state); a terminal that starts one opens the late listener
    /// check's window. The terminals running a command when it (re)starts are
    /// the baseline, not starts. Restarted when the workspaces change.
    private func watchCommands() {
        commandWatch?.cancel()
        commandWatch = Task { @MainActor [weak self] in
            var running: Set<UUID>?
            while !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let now = withObservationTracking {
                        Self.panelsRunningCommands()
                    } onChange: {
                        continuation.resume()
                    }
                    if let running, !now.subtracting(running).isEmpty { self?.lateListeners.commandStarted() }
                    running = now
                }
            }
        }
    }

    /// The own terminals whose shell runs a command now.
    private static func panelsRunningCommands() -> Set<UUID> {
        var panels: Set<UUID> = []
        for workspace in SupermuxLateListenerCheck.ownWorkspaces() {
            for (panelID, state) in workspace.panelShellActivityStates where state == .commandRunning {
                panels.insert(panelID)
            }
        }
        return panels
    }

    private func schedulePoke() {
        guard pendingPoke == nil else { return }
        pendingPoke = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.throttle)
            guard let self, !Task.isCancelled else { return }
            self.pendingPoke = nil
            MobileHostService.emitEvent(topic: Self.topic, payload: [:])
        }
    }
}

/// Catches a server that binds after its terminal's port scans are over, so it
/// is still attributed to its workspace: for ``window`` after one of this Mac's
/// terminals starts a command, it compares the loopback listeners (a full
/// process and socket scan) and, when one appears, re-kicks every own terminal's
/// port scan (one burst scans them all). Every ``fastInterval`` for the first
/// ``fastPeriod`` after the latest command start or new listener, then less often
/// as it stays quiet, up to ``slowestInterval``. Nothing runs between windows,
/// and it never pokes: an attribution changes the workspace's ports, which pokes.
@MainActor
final class SupermuxLateListenerCheck {
    static let window: Duration = .seconds(120)
    static let fastPeriod: Duration = .seconds(20)
    static let fastInterval: Duration = .seconds(4)
    static let slowestInterval: Duration = .seconds(30)

    private var task: Task<Void, Never>?
    private var windowEnds: ContinuousClock.Instant?
    private var lastActivity = ContinuousClock.now

    /// A terminal of this Mac started a command: (re)opens the window.
    func commandStarted() {
        let now = ContinuousClock.now
        windowEnds = now + Self.window
        lastActivity = now
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            var last: Set<Int>?
            while !Task.isCancelled {
                guard let self, let ends = self.windowEnds, ContinuousClock.now < ends else { break }
                let live = await Self.loopbackListeners()
                #if DEBUG
                SupermuxDeviceTunnelSocketCommands.liveChecks.increment()
                #endif
                guard !Task.isCancelled else { return }
                if let last, !live.subtracting(last).isEmpty {
                    Self.kickTerminalScans()
                    self.lastActivity = .now
                }
                last = live
                try? await Task.sleep(for: self.interval())
            }
            // The window ended (stop() already let go of a cancelled task).
            if !Task.isCancelled { self?.task = nil }
        }
    }

    /// No Mac follows this Mac's ports any more.
    func stop() {
        task?.cancel()
        task = nil
        windowEnds = nil
    }

    /// ``fastInterval`` for ``fastPeriod`` after the latest activity, then a
    /// quarter of the quiet time, at most ``slowestInterval``.
    private func interval() -> Duration {
        let quiet = ContinuousClock.now - lastActivity
        guard quiet > Self.fastPeriod else { return Self.fastInterval }
        return min(Self.slowestInterval, max(Self.fastInterval, quiet / 4))
    }

    /// This Mac's loopback listeners, without the ones this app holds for
    /// forwards and browser proxies.
    private static func loopbackListeners() async -> Set<Int> {
        await Task.detached(priority: .utility) {
            Set(IrxListeningPortScanner().loopbackListeningPorts().map(\.port))
        }.value.subtracting(SupermuxOwnListenerPorts.shared.all)
    }

    /// This Mac's own workspaces: not SSH, tmux or another Mac's mirror.
    static func ownWorkspaces() -> [Workspace] {
        SupermuxDeviceWorkspaceIndex.allMainWindowWorkspaces().filter {
            !$0.isRemoteWorkspace && !$0.isRemoteTmuxMirror && !SupermuxDeviceWorkspaceIndex.isDeviceMirror($0)
        }
    }

    /// Asks the sidebar's port detection to scan this Mac's own terminals again.
    private static func kickTerminalScans() {
        for workspace in ownWorkspaces() {
            for (panelID, panel) in workspace.panels where panel is TerminalPanel {
                PortScanner.shared.kick(workspaceId: workspace.id, panelId: panelID)
            }
        }
    }
}
