import Combine
import Foundation

/// Ticks mobile state sync v2 when a workspace's sidebar metadata changes:
/// `cmux set-status` pills, `set-progress`, `log`, and the git branch / PR.
///
/// Upstream's `MobileWorkspaceListObserver` hashes only the fields it knows,
/// and ``SupermuxMobileActivityObserver`` pokes only on agent lifecycle and
/// project association, so these changes would otherwise reach the phone and
/// other Macs (whose mirror rows render `supermux_status_entries`,
/// `supermux_progress`, `supermux_log`, `supermux_branch`,
/// `supermux_pull_request`) only on some unrelated tick.
///
/// Watches every main window's workspaces' `sidebarObservationPublisher` — the
/// same publisher the sidebar rows refresh from — and only while someone
/// subscribes to `mobile.sync.delta`, so an unpaired Mac pays nothing. A
/// device mirror's changes are skipped, checked as each one arrives: its pills
/// are the other Mac's, written by ``SupermuxDeviceStatusProjector``, and the
/// export filter never sends a mirror back. Every other change pokes the
/// shared ``SupermuxStateSyncTicker``, which coalesces it into one trailing
/// tick (or folds it into the activity observer's immediate one); the tick
/// itself is a no-op diff when nothing the record carries changed. Lives for
/// the app's lifetime (owned by ``SupermuxMobileHostGlue``).
@MainActor
final class SupermuxMobileSidebarStatusObserver {
    private let poke: @MainActor () -> Void
    private let hasSubscribers: @MainActor () -> Bool
    private let tabManagers: @MainActor () -> [TabManager]
    private var observers: [any NSObjectProtocol] = []
    private var tabsCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    private var workspaceCancellables: [UUID: AnyCancellable] = [:]

    init(
        poke: @escaping @MainActor () -> Void = { SupermuxStateSyncTicker.shared.request() },
        hasSubscribers: @escaping @MainActor () -> Bool = {
            MobileHostService.hasEventSubscribers(topic: MobileStateSyncHost.deltaTopic)
        },
        tabManagers: @escaping @MainActor () -> [TabManager] = SupermuxMobileSidebarStatusObserver.allTabManagers
    ) {
        self.poke = poke
        self.hasSubscribers = hasSubscribers
        self.tabManagers = tabManagers
        for name in [Notification.Name.mobileHostEventSubscriptionsDidChange, .mainWindowContextsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileAttachment() }
            })
        }
        reconcileAttachment()
    }

    /// Attaches the per-window pipelines while the delta topic has a
    /// subscriber, and tears them down when the last one leaves.
    private func reconcileAttachment() {
        guard hasSubscribers() else {
            tabsCancellables.removeAll()
            workspaceCancellables.removeAll()
            return
        }
        let managers = tabManagers()
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
        let workspaces = tabManagers().flatMap(\.tabs)
        let ids = Set(workspaces.map(\.id))
        workspaceCancellables = workspaceCancellables.filter { ids.contains($0.key) }
        for workspace in workspaces where workspaceCancellables[workspace.id] == nil {
            // The first value is the current state, not a change.
            workspaceCancellables[workspace.id] = workspace.sidebarObservationPublisher
                .dropFirst()
                .sink { [weak self, weak workspace] in
                    guard let workspace, !SupermuxDeviceWorkspaceIndex.isDeviceMirror(workspace) else { return }
                    self?.poke()
                }
        }
    }

    /// Every registered main window's tab manager.
    static func allTabManagers() -> [TabManager] {
        guard let app = AppDelegate.shared else { return [] }
        return app.listMainWindowSummaries().compactMap { app.tabManagerFor(windowId: $0.windowId) }
    }
}
