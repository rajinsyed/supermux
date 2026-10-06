import AppKit
import CmuxTerminal
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation
import SupermuxKit

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
///   Only while someone else would size the terminal, though: with nobody
///   else counting the engine holds the last grid, so a departed viewer's
///   size would outlive it. An off-screen pane nobody else would replace
///   keeps counting ("released"), and the terminal goes back to the pane's
///   own grid as soon as the last viewer leaves.
/// - Viewer: a device mirror reports `counts_override: false` to the other
///   Mac while its pane is off screen (`device-mirror-hidden-counts`).
///
/// An override someone set by hand is left alone: the automatic false is
/// only lifted when it is still the value this class set.
///
/// A pane goes off screen only once it stays so for a moment: the portal
/// hides a pane briefly during layout and split churn. Its reveal posts no
/// visibility change, so the portal (`sizing-portal-reveal`) looks again, and
/// so do input on the pane (`sizing-mac-pane-input-recheck`) and every sizing
/// decision (`sizing-mac-pane-recheck`): nobody counting holds the grid, so a
/// shown pane still marked off screen kept a departed phone's size.
///
/// While someone else would size the terminal, a marked pane comes back only
/// once it stays on screen for a moment too. The mark's own publish makes
/// SwiftUI reconcile the pane, which un-hides a pane the portal hid until the
/// portal hides it again a few ms later. Lifting the mark on that reveal
/// resized the terminal back to the pane's grid, the next settle marked it
/// again, and the grid flapped between the two sizes about every 100 ms.
///
/// Also: a terminal whose runtime starts after its shared grid was decided
/// gets that grid when it becomes ready (upstream applies only to a live
/// surface and never retries).
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
    /// Local terminals whose Mac pane is off screen but still counts, because
    /// nobody else would size the terminal. Disjoint from `hiddenHosts`.
    private var releasedHosts: Set<UUID> = []
    /// Marked panes seen on screen, waiting to stay there through the settle
    /// (`showWhenSettled`), each with its wait's token: seeing the pane off
    /// screen again ends the wait, and a later wait's timer is the only one
    /// that may end the new one.
    private var pendingShows: [UUID: UUID] = [:]
    private var observers: [NSObjectProtocol] = []

    /// Starts following visibility changes. Later calls are no-ops.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .terminalPortalVisibilityDidChange, object: nil, queue: .main) { [weak self] note in
            let surfaceID = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID
            MainActor.assumeIsolated { self?.refresh(surfaceID: surfaceID) }
        })
        observers.append(center.addObserver(forName: .terminalSurfaceDidBecomeReady, object: nil, queue: .main) { [weak self] note in
            let surfaceID = note.userInfo?["surfaceId"] as? UUID
            MainActor.assumeIsolated {
                guard let surfaceID else { return }
                self?.applyDecidedGrid(surfaceID)
                self?.refresh(surfaceID: surfaceID)
            }
        })
        // A workspace mounted again shows its pane before the pane is back in
        // its window (the portal binds it a moment later), so the visibility
        // change above can find it off screen; look again once it is in the window.
        observers.append(center.addObserver(forName: .terminalSurfaceHostedViewDidMoveToWindow, object: nil, queue: .main) { [weak self] note in
            let surfaceID = note.userInfo?["surfaceId"] as? UUID
            MainActor.assumeIsolated {
                guard let surfaceID else { return }
                Task { @MainActor [weak self] in self?.refresh(surfaceID: surfaceID) }
            }
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
        refreshMirror(surface.id, settled: true)
        // A pane bound while it is being mounted reaches its window a turn later.
        let surfaceID = surface.id
        Task { @MainActor [weak self] in self?.refreshMirror(surfaceID, settled: true) }
    }

    func untrack(surfaceID: UUID) {
        mirrors[surfaceID] = nil
    }

    /// The live device mirrors, by local surface id (SupermuxTerminalSizingDefaults
    /// applies this Mac's size preference to each).
    func trackedMirrorSessions() -> [UUID: DeviceTerminalMirrorSession] {
        mirrors.compactMapValues(\.session)
    }

    /// The live device mirror shown in the local surface `surfaceID`.
    func mirrorSession(for surfaceID: UUID) -> DeviceTerminalMirrorSession? {
        mirrors[surfaceID]?.session
    }

    /// Another live pane of `session`'s terminal on the same link (client id),
    /// on screen when `shown`: the pane that takes over speaking for this Mac
    /// when `session`'s pane goes off screen or closes.
    func sibling(of session: DeviceTerminalMirrorSession, shown: Bool) -> DeviceTerminalMirrorSession? {
        guard let clientID = session.viewer?.clientID else { return nil }
        return mirrors.values.lazy.compactMap(\.session).first { other in
            other !== session && other.phase != .stopped
                && other.remoteSurfaceID == session.remoteSurfaceID
                && other.viewer?.clientID == clientID
                && (!shown || !other.supermuxHidden)
        }
    }

    // MARK: - Host (local terminals with viewers)

    /// Called as a local terminal's sizing host is created. Only the Mac
    /// pane is attached yet, so an off-screen pane starts out released: it
    /// stops counting once another viewer attaches (`hostWillApply`), before
    /// that viewer's first grid is applied.
    func prepareHost(_ host: inout LocalTerminalSizingHost, surface: TerminalSurface) {
        start()
        hiddenHosts.remove(surface.id)
        releasedHosts.remove(surface.id)
        guard !Self.isOnScreen(surface) else { return }
        releasedHosts.insert(surface.id)
    }

    /// Called before a local terminal's sizing decision applies, so the
    /// decision never holds a departed viewer's size. A set lookup unless the
    /// pane is off screen.
    /// - On screen: the pane counts again; while someone else would size the
    ///   terminal, only once it stays on screen (`showWhenSettled`).
    /// - Marked, but nobody else would size the terminal any more: the pane
    ///   counts again, released.
    /// - Released, and someone else would size it now: marked again.
    /// The caller's immediacy is kept: a leave applies now, a TTL expiry
    /// after the governor's window.
    func hostWillApply(surfaceID: UUID) {
        let marked = hiddenHosts.contains(surfaceID)
        guard marked || releasedHosts.contains(surfaceID) else { return }
        let controller = TerminalController.shared
        guard var host = controller.localSizingHostsBySurfaceID[surfaceID],
              let surface = controller.terminalSocketTarget(surfaceID: surfaceID)?.surface,
              let row = host.state.participant(host.macParticipantID) else { return }
        let override = row.participant.countsOverride
        let onScreen = Self.isOnScreen(surface)
        if !onScreen { showInterrupted(surfaceID) }
        let value: Bool?
        if onScreen, marked, override == false, Self.othersWouldCount(host) {
            showWhenSettled(surfaceID)
            return
        } else if onScreen {
            hiddenHosts.remove(surfaceID)
            releasedHosts.remove(surfaceID)
            guard marked, override == false else { return }
            value = nil
        } else if marked, !Self.othersWouldCount(host) {
            hiddenHosts.remove(surfaceID)
            releasedHosts.insert(surfaceID)
            guard override == false else { return }
            value = nil
        } else if !marked, override == nil, Self.othersWouldCount(host) {
            releasedHosts.remove(surfaceID)
            hiddenHosts.insert(surfaceID)
            value = false
        } else {
            return
        }
        host.setCountsOverride(host.macParticipantID, value)
        controller.localSizingHostsBySurfaceID[surfaceID] = host
    }

    /// Whether the Mac pane's `counts_override: false` is this class's
    /// off-screen mark, not an override someone set by hand.
    func marksOffScreen(_ surfaceID: UUID) -> Bool {
        hiddenHosts.contains(surfaceID)
    }

    /// Someone set the Mac pane's counts override by hand (the size panel,
    /// `terminal.size_counts.set`; `sizing-user-mac-counts`): it is theirs,
    /// so it is neither this class's mark to lift nor a released pane's.
    /// Before, a hand-set false on a pane already marked looked like the mark
    /// and was lifted once nobody else counted. This class's own mark goes
    /// through the same setter (`refreshHost`) and records itself right after.
    func userSetMacCounts(_ surfaceID: UUID) {
        hiddenHosts.remove(surfaceID)
        releasedHosts.remove(surfaceID)
    }

    /// Whether someone other than the Mac pane would size the terminal if
    /// the pane stopped counting: it has a viewport and is not opted out.
    private static func othersWouldCount(_ host: LocalTerminalSizingHost) -> Bool {
        host.state.participants.contains { row in
            row.id != host.macParticipantID && row.participant.viewport != nil
                && row.participant.countsOverride != false
        }
    }

    /// The portal revealed a pane it had hidden (layout churn): look again,
    /// once the reveal's layout pass is over.
    func paneRevealed(_ surfaceID: UUID?) {
        guard let surfaceID else { return }
        Task { @MainActor [weak self] in self?.refresh(surfaceID: surfaceID) }
    }

    /// Input on a Mac pane, a mirror's included. A pane marked off screen
    /// evidently is not: look again. Two lookups otherwise, as this runs on
    /// every keystroke.
    func macPaneInput(_ surfaceID: UUID) {
        if hiddenHosts.contains(surfaceID) {
            refreshHost(surfaceID)
        } else if mirrors[surfaceID]?.session?.supermuxHidden == true {
            refreshMirror(surfaceID)
        }
    }

    /// A pane's grid changed. A pane shown for the first time gets its real
    /// size here without a visibility change (it starts out "visible" before
    /// it has a window), so look again once layout settles.
    func surfaceGeometryChanged(_ surfaceID: UUID) {
        Task { @MainActor [weak self] in self?.refresh(surfaceID: surfaceID) }
    }

    /// A terminal whose runtime starts after its shared grid was decided
    /// (a tab opened from a mirror starts in the background when the mirror
    /// first attaches) missed the apply, which needs a live surface: apply
    /// the decided grid now. The governor may already count that request as
    /// done, so apply past it, but record it there first: only the governor's
    /// record lifts a pin, so a pin it does not know of outlived its reason.
    private func applyDecidedGrid(_ surfaceID: UUID) {
        let controller = TerminalController.shared
        guard let host = controller.localSizingHostsBySurfaceID[surfaceID],
              case let .grid(size) = host.applyTarget else { return }
        let reason = "supermux.sizing.runtimeReady"
        controller.governMobileViewportTarget(
            surfaceID: surfaceID, target: .cap(columns: size.cols, rows: size.rows), immediate: true, reason: reason
        )
        _ = controller.performMobileViewportTarget(
            surfaceID: surfaceID, target: .cap(columns: size.cols, rows: size.rows), reason: reason
        )
    }

    // MARK: - Updates

    /// Looks at every tracked pane again, as any window's occlusion change does.
    func recheckAll() {
        refresh(surfaceID: nil)
    }

    private func refresh(surfaceID: UUID?) {
        if let surfaceID {
            refreshMirror(surfaceID)
            refreshHost(surfaceID)
            return
        }
        for surfaceID in Array(mirrors.keys) { refreshMirror(surfaceID) }
        for surfaceID in Array(TerminalController.shared.localSizingHostsBySurfaceID.keys) { refreshHost(surfaceID) }
    }

    /// Shows at once; hides only once the pane is still off screen a moment
    /// later (`settled` skips that wait, for a pane just bound). A pane is
    /// re-hosted, briefly out of its window, when a tab or the focus changes
    /// beside it: hiding on that flicker made a shown pane give up speaking
    /// for this Mac and told the other Mac this Mac does not count.
    private func refreshMirror(_ surfaceID: UUID, settled: Bool = false) {
        guard let tracked = mirrors[surfaceID] else { return }
        guard let session = tracked.session, let surface = tracked.surface else {
            mirrors[surfaceID] = nil
            return
        }
        let onScreen = Self.isOnScreen(surface)
        guard !onScreen, !session.supermuxHidden, !settled else {
            session.supermuxSetHidden(!onScreen)
            SupermuxDeviceTerminalActions.visibilityChanged(surface)
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.hideSettleNanoseconds)
            self?.refreshMirror(surfaceID, settled: true)
        }
    }

    /// How long a pane must stay off screen before it counts as hidden, and a
    /// marked pane on screen before it counts again.
    private static let hideSettleNanoseconds: UInt64 = 250_000_000

    /// Hides, as a mirror does, only once the pane is still off screen a
    /// moment later (the portal hides a pane briefly during layout). A hidden
    /// pane nobody else would replace is released instead of marked. Shows a
    /// marked pane once it stays on screen (`showWhenSettled`), at once when
    /// nobody else would size the terminal.
    private func refreshHost(_ surfaceID: UUID, settled: Bool = false) {
        let controller = TerminalController.shared
        guard let host = controller.localSizingHostsBySurfaceID[surfaceID] else {
            hiddenHosts.remove(surfaceID)
            releasedHosts.remove(surfaceID)
            return
        }
        guard let surface = controller.terminalSocketTarget(surfaceID: surfaceID)?.surface else { return }
        let macID = host.macParticipantID
        let current = host.state.participant(macID)?.participant.countsOverride
        if !Self.isOnScreen(surface) {
            showInterrupted(surfaceID)
            // A released pane is hostWillApply's: it marks it once someone else counts.
            guard current == nil, !releasedHosts.contains(surfaceID) else { return }
            guard settled else {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: Self.hideSettleNanoseconds)
                    self?.refreshHost(surfaceID, settled: true)
                }
                return
            }
            guard Self.othersWouldCount(host) else {
                releasedHosts.insert(surfaceID)
                return
            }
            if controller.localSizingSetCountsOverride(surfaceID: surfaceID, participantID: macID, value: false) {
                hiddenHosts.insert(surfaceID)
            }
        } else if releasedHosts.remove(surfaceID) != nil {
            return
        } else if hiddenHosts.contains(surfaceID), current == false, Self.othersWouldCount(host) {
            showWhenSettled(surfaceID)
        } else if hiddenHosts.remove(surfaceID) != nil, current == false {
            liftMark(surfaceID)
        }
    }

    /// Lifts the mark of a pane seen on screen once it stayed there through
    /// the settle; seeing it off screen meanwhile cancels the wait
    /// (`showInterrupted`). A reveal the portal undoes a few ms later is no
    /// return.
    private func showWhenSettled(_ surfaceID: UUID) {
        guard pendingShows[surfaceID] == nil else { return }
        // A timer of an interrupted wait must not end this one early.
        let token = UUID()
        pendingShows[surfaceID] = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.hideSettleNanoseconds)
            guard let self, self.pendingShows[surfaceID] == token else { return }
            self.pendingShows[surfaceID] = nil
            let controller = TerminalController.shared
            guard let host = controller.localSizingHostsBySurfaceID[surfaceID],
                  let surface = controller.terminalSocketTarget(surfaceID: surfaceID)?.surface,
                  Self.isOnScreen(surface),
                  host.state.participant(host.macParticipantID)?.participant.countsOverride == false,
                  self.hiddenHosts.remove(surfaceID) != nil else { return }
            self.liftMark(surfaceID)
        }
    }

    /// The pane was seen off screen while its show waited to settle: the show
    /// did not hold. Looks again a settle later, as the reveal that ends this
    /// hide may post nothing.
    private func showInterrupted(_ surfaceID: UUID) {
        guard pendingShows.removeValue(forKey: surfaceID) != nil else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.hideSettleNanoseconds)
            self?.refreshHost(surfaceID)
        }
    }

    /// The marked pane is on screen: it counts again. Coming on screen is an
    /// explicit return, not a flap: apply at once rather than after the
    /// governor's uncap window.
    private func liftMark(_ surfaceID: UUID) {
        let controller = TerminalController.shared
        guard var host = controller.localSizingHostsBySurfaceID[surfaceID] else { return }
        let previous = host.state
        host.setCountsOverride(host.macParticipantID, nil)
        controller.localSizingHostsBySurfaceID[surfaceID] = host
        _ = controller.applyLocalSizing(surfaceID: surfaceID, previous: previous, immediate: true, reason: "supermux.sizing.onScreen")
    }

    /// On screen: shown in its workspace, in a visible window that is not
    /// fully covered.
    static func isOnScreen(_ surface: TerminalSurface) -> Bool {
        let view = surface.hostedView
        guard view.isVisibleInUI, !view.isHiddenOrHasHiddenAncestor, let window = view.window else { return false }
        // Not trusting the active Space: a background pane's view can sit in
        // an ordered-in holder window off screen.
        return SupermuxWindowVisibility.windowIsOnScreen(window, trustingActiveSpace: false)
    }
}
