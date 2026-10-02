import Combine
import Foundation
import SupermuxMobileCore

/// Pokes the user's other Macs (`supermux.ports.updated`) when the ports this
/// Mac's workspaces listen on change, so their forwards follow within a moment
/// instead of on the next link connect. They refetch `ports.list` on receipt.
///
/// Watches every main window's workspaces' `listeningPorts` (the sidebar's
/// port detection), only while a device link subscribes to the topic, so a
/// Mac nobody forwards from pays nothing. Pokes are coalesced into one per
/// ``throttle`` window. Lives for the app's lifetime (owned by
/// ``SupermuxMobileHostGlue``); the attach/detach pattern is
/// ``SupermuxMobileSidebarStatusObserver``'s.
@MainActor
final class SupermuxHostPortsObserver {
    static let throttle: Duration = .milliseconds(500)
    private static let topic = SupermuxMobileTopic.portsUpdated.rawValue

    private var observers: [any NSObjectProtocol] = []
    private var tabsCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    private var workspaceCancellables: [UUID: AnyCancellable] = [:]
    private var pendingPoke: Task<Void, Never>?

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
        // A workspace that appears or goes may take ports with it.
        schedulePoke()
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
