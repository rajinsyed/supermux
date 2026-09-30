import AppKit
import CmuxTerminal
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation

/// A terminal pane that nobody can see does not size a shared terminal.
///
/// Upstream's shared sizing counts every attached view, including a Mac pane
/// that is off screen. A tab created in a background workspace of another Mac
/// (a new tab opened from a device mirror) has never been laid out there, so
/// its small default grid held the terminal down under "Fit everyone" until
/// someone opened the tab on that Mac. Here a pane counts only while it is on
/// screen: on its own window, in the selected workspace, in a window that is
/// not hidden or fully covered.
///
/// - Host: a local terminal's own Mac pane gets `counts_override: false`
///   while off screen and its automatic rule back when it shows again
///   (`sizing-hidden-mac-pane` touchpoint for a new host, updates here).
/// - Viewer: a device mirror reports `counts_override: false` to the other
///   Mac while its pane is off screen (`device-mirror-hidden-counts`).
///
/// An override someone set by hand is left alone: the automatic false is
/// only lifted when it is still the value this class set.
@MainActor
final class SupermuxTerminalSizingVisibility {
    static let shared = SupermuxTerminalSizingVisibility()

    private struct TrackedMirror {
        weak var session: DeviceTerminalMirrorSession?
        weak var surface: TerminalSurface?
    }

    private var mirrors: [UUID: TrackedMirror] = [:]
    /// Local terminals whose Mac pane this class marked as not counting.
    private var hiddenHosts: Set<UUID> = []
    private var observers: [NSObjectProtocol] = []

    /// Starts following visibility changes. Later calls are no-ops.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .terminalPortalVisibilityDidChange, object: nil, queue: .main) { [weak self] note in
            let surfaceID = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID
            MainActor.assumeIsolated { self?.refresh(surfaceID: surfaceID) }
        })
        for name in [NSWindow.didChangeOcclusionStateNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(surfaceID: nil) }
            })
        }
    }

    // MARK: - Viewer (device mirrors)

    func track(_ session: DeviceTerminalMirrorSession, surface: TerminalSurface) {
        start()
        mirrors[surface.id] = TrackedMirror(session: session, surface: surface)
        refreshMirror(surface.id)
        // A pane bound while it is being mounted reaches its window a turn later.
        let surfaceID = surface.id
        Task { @MainActor [weak self] in self?.refreshMirror(surfaceID) }
    }

    func untrack(surfaceID: UUID) {
        mirrors[surfaceID] = nil
    }

    // MARK: - Host (local terminals with viewers)

    /// Called as a local terminal's sizing host is created: an off-screen
    /// Mac pane starts out not counting, before the first grid is applied.
    func prepareHost(_ host: inout LocalTerminalSizingHost, surface: TerminalSurface) {
        start()
        guard !Self.isOnScreen(surface) else { return }
        host.setCountsOverride(host.macParticipantID, false)
        hiddenHosts.insert(surface.id)
    }

    /// A pane's grid changed. A pane shown for the first time gets its real
    /// size here without a visibility change (it starts out "visible" before
    /// it has a window), so look again once layout settles.
    func surfaceGeometryChanged(_ surfaceID: UUID) {
        Task { @MainActor [weak self] in self?.refresh(surfaceID: surfaceID) }
    }

    // MARK: - Updates

    private func refresh(surfaceID: UUID?) {
        if let surfaceID {
            refreshMirror(surfaceID)
            refreshHost(surfaceID)
            return
        }
        Array(mirrors.keys).forEach(refreshMirror)
        Array(TerminalController.shared.localSizingHostsBySurfaceID.keys).forEach(refreshHost)
    }

    private func refreshMirror(_ surfaceID: UUID) {
        guard let tracked = mirrors[surfaceID] else { return }
        guard let session = tracked.session, let surface = tracked.surface else {
            mirrors[surfaceID] = nil
            return
        }
        session.supermuxSetHidden(!Self.isOnScreen(surface))
    }

    private func refreshHost(_ surfaceID: UUID) {
        let controller = TerminalController.shared
        guard let host = controller.localSizingHostsBySurfaceID[surfaceID] else {
            hiddenHosts.remove(surfaceID)
            return
        }
        guard let surface = controller.terminalSocketTarget(surfaceID: surfaceID)?.surface else { return }
        let macID = host.macParticipantID
        let current = host.state.participant(macID)?.participant.countsOverride
        if !Self.isOnScreen(surface) {
            guard current == nil else { return }
            if controller.localSizingSetCountsOverride(surfaceID: surfaceID, participantID: macID, value: false) {
                hiddenHosts.insert(surfaceID)
            }
        } else if hiddenHosts.remove(surfaceID) != nil, current == false {
            _ = controller.localSizingSetCountsOverride(surfaceID: surfaceID, participantID: macID, value: nil)
        }
    }

    /// On screen: shown in its workspace, in a visible window that is not
    /// fully covered.
    static func isOnScreen(_ surface: TerminalSurface) -> Bool {
        let view = surface.hostedView
        guard view.isVisibleInUI, !view.isHiddenOrHasHiddenAncestor, let window = view.window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }
}
