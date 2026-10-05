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
        // A window that opens or closes starts the workspaces over: one that
        // reopens restores its workspaces as new objects with the same IDs.
        if live != Set(tabsCancellables.keys) {
            workspaceCancellables.removeAll()
            lastWorkspaceIDs = nil
        }
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
/// is still attributed to its workspace: at each of ``checkOffsets`` after the
/// latest time one of this Mac's terminals started a command, it compares the
/// loopback listeners (a full process and socket scan) and, when one appeared
/// since the previous check, re-kicks every own terminal's port scan (one burst
/// scans them all). The window ends with the last offset, not when the command
/// exits (a daemonized server binds later). Its first check is the baseline: a
/// server that bound before it is in its terminal's own port scans (about 10 s
/// after the command starts). A command start never postpones a check already
/// due, and checks stay ``minimumGap`` apart, so a burst of commands scans no
/// more often. Nothing runs between windows, and it never pokes: an
/// attribution changes the workspace's ports, which pokes.
@MainActor
final class SupermuxLateListenerCheck {
    /// When the checks run, counted from the latest command start: 10 s apart
    /// for the first 25 s, where a dev script's server usually binds (after an
    /// install or a build), so it is attributed within about 10 s; sparser after.
    static let checkOffsets: [Duration] = [.seconds(5), .seconds(15), .seconds(25), .seconds(45), .seconds(120)]
    /// The least time between two checks.
    static let minimumGap: Duration = .seconds(5)

    private var task: Task<Void, Never>?
    private var latestStart: ContinuousClock.Instant?
    /// When the pending (or running) check is due.
    private var nextCheck: ContinuousClock.Instant?
    /// The previous check's listeners in this window.
    private var listeners: Set<Int>?

    /// A terminal of this Mac started a command: (re)opens the window, and
    /// brings the next check forward when it is due later than the first offset.
    func commandStarted() {
        let now = ContinuousClock.now
        latestStart = now
        let first = now + Self.checkOffsets[0]
        if let nextCheck, nextCheck <= first { return }
        run(from: first)
    }

    /// No Mac follows this Mac's ports any more.
    func stop() {
        task?.cancel()
        endWindow()
    }

    /// Runs the checks from `first` until the window ends, replacing a pending
    /// one. Only a check still waiting is ever replaced: a running one is due
    /// already, so ``commandStarted()`` keeps it.
    private func run(from first: ContinuousClock.Instant) {
        task?.cancel()
        nextCheck = first
        task = Task { @MainActor [weak self] in
            var due = first
            while true {
                // Cancelled while waiting: replaced by a sooner check, or stopped.
                guard (try? await Task.sleep(until: due, clock: .continuous)) != nil else { return }
                let live = await Self.loopbackListeners()
                #if DEBUG
                SupermuxDeviceTunnelSocketCommands.liveChecks.increment()
                #endif
                // Stopped while scanning (a new window may run already).
                guard let self, !Task.isCancelled else { return }
                if let listeners = self.listeners, !live.subtracting(listeners).isEmpty {
                    Self.kickTerminalScans()
                }
                self.listeners = live
                guard let next = self.check(after: .now) else { break }
                due = next
                self.nextCheck = next
            }
            self?.endWindow()
        }
    }

    /// The first of ``checkOffsets`` after the latest command start that is at
    /// least ``minimumGap`` after `now`; nil once the window is over.
    private func check(after now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard let latestStart else { return nil }
        return Self.checkOffsets.map { latestStart + $0 }.first { $0 >= now + Self.minimumGap }
    }

    private func endWindow() {
        task = nil
        latestStart = nil
        nextCheck = nil
        listeners = nil
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
