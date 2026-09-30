import Foundation
import Observation

/// Host side of remote-workspace layout sync: notices tab changes in a
/// workspace nobody is looking at on this Mac.
///
/// Upstream's `DeviceWorkspaceLayoutHost` re-captures (and publishes) a
/// workspace's layout only on `.workspacePaneGeometryDidChange`, which a
/// workspace posts only while its split view is on screen. A tab added,
/// closed, moved or reordered in a background workspace (an agent spawning a
/// terminal, the phone's `mobile.terminal.create`, a preset, a CLI
/// `new-surface`) therefore never reached another Mac's mirror until some
/// unrelated geometry change.
///
/// Bonsplit's split tree and the pane registry are `@Observable`, so a capture
/// run through ``capture(_:_:)`` records exactly what it read (panes, tab order,
/// selection, divider positions, panel identities). The first change to any of
/// it asks the host to capture that workspace again, coalesced to one capture
/// per workspace per ``coalescingDelay``. The host still publishes only when
/// the arrangement actually changed, so selection or title churn costs one
/// cheap capture and sends nothing. Installed by the
/// `device-layout-tab-changes` touchpoint in `DeviceWorkspaceLayoutHost`.
@MainActor
final class SupermuxDeviceLayoutChangeObserver {
    /// How long a burst of tab mutations (create, select, register) settles
    /// before the workspace is captured again.
    static let coalescingDelay: Duration = .milliseconds(40)

    private let recapture: @MainActor (UUID) -> Void
    /// Workspaces whose last capture is being observed; a change disarms them.
    private var armed: Set<UUID> = []
    private var pending: Set<UUID> = []
    private var flush: Task<Void, Never>?

    /// - Parameter recapture: Captures (and, when changed, publishes) one
    ///   workspace's layout again; it should call ``capture(_:_:)`` to re-arm.
    init(recapture: @escaping @MainActor (UUID) -> Void) {
        self.recapture = recapture
    }

    /// Runs `body` (one workspace's layout capture) and, unless that workspace
    /// is already observed, observes everything it reads.
    func capture<Value>(_ workspaceID: UUID, _ body: () -> Value?) -> Value? {
        guard !armed.contains(workspaceID) else { return body() }
        let value = withObservationTracking {
            body()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.changed(workspaceID) }
        }
        // A workspace that is gone reads nothing observable; do not mark it,
        // so its next successful capture observes again.
        if value != nil { armed.insert(workspaceID) }
        return value
    }

    private func changed(_ workspaceID: UUID) {
        armed.remove(workspaceID)
        pending.insert(workspaceID)
        guard flush == nil else { return }
        flush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.coalescingDelay)
            self?.drain()
        }
    }

    private func drain() {
        flush = nil
        let workspaceIDs = pending
        pending.removeAll()
        for workspaceID in workspaceIDs { recapture(workspaceID) }
    }
}
