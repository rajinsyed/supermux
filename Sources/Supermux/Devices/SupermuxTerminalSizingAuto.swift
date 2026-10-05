import AppKit
import Bonsplit
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation

/// Auto, the default size mode: the device you are viewing a terminal from
/// sets its grid, the phone included.
///
/// Auto is upstream's `latest` mode ("Follow Latest": the counting view with
/// the newest activity owns the grid). Two upstream rules kept it from
/// following the device in use, and this class lifts both in the host layer
/// (the shared engine and its fixtures are unchanged):
///
/// - **A phone defers to a Mac pane on screen.** The engine does not count a
///   phone while a Mac of the same user counts, in every mode but Fit
///   everyone and Largest Window, so under `latest` the phone never won. In
///   Auto, a phone (or iPad) whose user set no counts override gets
///   `counts_override: true` from this class. Overrides the user set are
///   never replaced ("Counts toward size" off stays off); the ones this
///   class set are cleared when the terminal leaves Auto.
/// - **Viewing was not activity.** Only attaching and typing were. In Auto a
///   viewer also becomes the newest when it starts viewing: a phone opening
///   the terminal or returning to it (its viewport report attaches it again
///   after it cleared it on leaving), a viewport that changed (a rotation, a
///   resized window), and another Mac's mirror shown again (its
///   `counts_override` goes from false back to automatic), and a phone whose
///   terminal view came back on screen without leaving the terminal (it
///   navigated away and back: its report repeats the viewport but carries
///   `view_appeared: true`, ``viewAppearedClientID``; another Mac's mirror
///   sends it for Size to My Window and for its app becoming active with
///   the mirror focused). Any other report that
///   repeats the same viewport is no activity: the phone sends one in answer
///   to every grid change, which would hand the grid back and forth.
///
/// On the Mac, typing, a paste and a focus click were already activity;
/// this class adds the app becoming active with a terminal (or its TextBox)
/// focused, and a scroll on the pane. A pane merely coming on screen is
/// not: selecting a workspace on the phone selects it on the Mac too, and
/// would take the grid from the phone. The reverse holds as well: an awake
/// phone follows the Mac's selection and attaches to the terminal the Mac's
/// user just selected, which would take the grid from the Mac. So a phone
/// attaching to or starting to view a terminal within 3 s of this Mac's
/// user selecting it leaves the Mac pane the newest
/// (``macUserSelected(workspace:)``, ``macUserSelected(panelID:)``). A
/// mirror's Size to My Window or activation claim still wins: it is never a
/// view following this Mac's selection.
///
/// Only this Mac's user is the Mac pane's activity (``isMacPaneActivity``).
/// Every terminal input path runs the pane's explicit-input hook: a phone's
/// keystrokes over its input lane or RPC, a paste's Return sent a turn
/// later, another Mac's mirror, a socket client's text. Counted as the Mac
/// pane typing, each one handed the grid from the viewer that typed to the
/// Mac and back, so the terminal flashed between their sizes on every key.
@MainActor
final class SupermuxTerminalSizingAuto {
    static let shared = SupermuxTerminalSizingAuto()

    /// Phones this class made count, by terminal: the overrides it may clear.
    private var autoCounted: [UUID: Set<String>] = [:]
    /// Set while an action of this Mac's user that is no input event notes
    /// the Mac pane's activity (``noteMacAction(surfaceID:)``).
    private var notingMacAction = false
    /// The client whose `mobile.terminal.viewport` report is being handled
    /// and says its terminal view just came back on screen
    /// (`view_appeared: true`). Set by `v2MobileTerminalViewport` around the
    /// report only (SUPERMUX-TOUCHPOINTS.md #881).
    var viewAppearedClientID: String?
    /// Terminals this Mac's user selected (a workspace, a tab, a pane), by
    /// panel id, with when (system uptime).
    private var macSelections: [UUID: TimeInterval] = [:]
    /// How long after this Mac's user selects a terminal a phone that only
    /// attaches to it does not take its grid.
    private static let macSelectionWindow: TimeInterval = 3
    private var observer: NSObjectProtocol?
    #if DEBUG
    /// How many times the app becoming active noted a focused terminal's
    /// Mac pane activity (`terminal_sizing.state`): lets the E2E tell an
    /// activation apart from input.
    private(set) var macActivations = 0
    #endif

    /// Starts following app activation. Later calls are no-ops.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SupermuxTerminalSizingAuto.shared.focusedTerminalActivated() }
        }
    }

    // MARK: - Host rules

    /// The viewers' reports were synced into a local terminal's host
    /// (`resolveSharedSizing`). `explicitParticipantID` is the viewer whose
    /// report carried a `counts_override`: its override is the user's now.
    func viewersReported(
        _ host: inout LocalTerminalSizingHost,
        surfaceID: UUID,
        previous: TerminalSizingState,
        explicitParticipantID: String?
    ) {
        if let explicitParticipantID { autoCounted[surfaceID]?.remove(explicitParticipantID) }
        // `view_appeared` is activity in every mode: it decides once the
        // terminal is in Auto, so a mirror's Size to My Window that switches
        // Fit everyone to Auto wins whichever of its two requests lands first.
        let auto = host.state.policy.mode == .latest
        let appeared = viewAppearedClientID.map { LocalTerminalSizingHost.phoneParticipantID(clientID: $0) }
        // Another Mac's mirror sends `view_appeared` only for its user's Size
        // to My Window or app activation: an explicit claim, never a view
        // that follows this Mac's selection, so it is noted last.
        let mirrorClaim = appeared.flatMap { id in
            host.state.participant(id)?.participant.deviceKind.isHandheld == false ? id : nil
        }
        var phoneStarted = false
        for id in host.phoneParticipantIDs where id != mirrorClaim {
            if id == appeared || (auto && Self.startedViewing(id, now: host.state, before: previous)) {
                host.noteActivity(id)
                phoneStarted = true
            } else if previous.participant(id) == nil {
                phoneStarted = true
            }
        }
        if auto, phoneStarted { keepMacSelection(&host, surfaceID: surfaceID) }
        if let mirrorClaim, host.phoneParticipantIDs.contains(mirrorClaim) { host.noteActivity(mirrorClaim) }
        reconcileCounts(&host, surfaceID: surfaceID)
    }

    /// The terminal's policy changed: Auto's counts overrides follow the mode.
    func policyChanged(_ host: inout LocalTerminalSizingHost, surfaceID: UUID) {
        reconcileCounts(&host, surfaceID: surfaceID)
    }

    /// Someone set a counts override by hand (size panel, socket): it is theirs.
    func userSetCounts(participantID: String, surfaceID: UUID) {
        autoCounted[surfaceID]?.remove(participantID)
    }

    /// A viewer already attached started viewing: its viewport changed, or a
    /// `counts_override` of false (a hidden mirror) was lifted. Attaching is
    /// activity in the engine already.
    private static func startedViewing(_ id: String, now: TerminalSizingState, before: TerminalSizingState) -> Bool {
        guard let old = before.participant(id)?.participant, let new = now.participant(id)?.participant else {
            return false
        }
        return old.viewport != new.viewport || (old.countsOverride == false && new.countsOverride != false)
    }

    /// In Auto every phone without an override of its own counts; out of it,
    /// the overrides this class set are cleared.
    private func reconcileCounts(_ host: inout LocalTerminalSizingHost, surfaceID: UUID) {
        var mine = autoCounted[surfaceID] ?? []
        let auto = host.state.policy.mode == .latest
        for row in host.state.participants where row.id != host.macParticipantID {
            let override = row.participant.countsOverride
            if auto, override == nil, row.participant.deviceKind.isHandheld {
                host.setCountsOverride(row.id, true)
                mine.insert(row.id)
            } else if !auto, mine.remove(row.id) != nil, override == true {
                host.setCountsOverride(row.id, nil)
            }
        }
        mine.formIntersection(host.phoneParticipantIDs)
        autoCounted[surfaceID] = mine.isEmpty ? nil : mine
        if autoCounted.count > 64 { pruneClosedTerminals() }
    }

    private func pruneClosedTerminals() {
        let hosts = TerminalController.shared.localSizingHostsBySurfaceID
        autoCounted = autoCounted.filter { hosts[$0.key] != nil }
    }

    // MARK: - The Mac

    /// Whether explicit input on a Mac pane right now is this Mac's user's:
    /// an input event or menu action the app is dispatching
    /// (``SupermuxLocalUserInput``), or one of their actions that is no input
    /// event. A guard in `noteLocalTerminalSizingActivity`, which runs on
    /// every keystroke: two flag reads and a run-loop mode compare.
    var isMacPaneActivity: Bool {
        notingMacAction || SupermuxLocalUserInput.isHandling
    }

    /// Notes the Mac pane's activity for an action of this Mac's user that is
    /// no input event: Size to Me (from any entry point), the app becoming
    /// active with the terminal focused. A mirror of another Mac's terminal
    /// has no host here: unless it already sizes that terminal, it claims
    /// the grid as its Size to My Window does.
    func noteMacAction(surfaceID: UUID) {
        let enclosing = notingMacAction
        notingMacAction = true
        defer { notingMacAction = enclosing }
        let controller = TerminalController.shared
        controller.noteLocalTerminalSizingActivity(surfaceID: surfaceID)
        guard controller.localSizingHostsBySurfaceID[surfaceID] == nil,
              let mirror = SupermuxTerminalSizingVisibility.shared.mirrorSession(for: surfaceID),
              !mirror.supermuxOwnsGrid else { return }
        mirror.sharingNoteSelfActivity()
    }

    /// Size to My Window on a local terminal, from any entry point: notes the
    /// Mac pane's activity, then puts the decided size on the PTY now.
    ///
    /// Noting activity alone changes nothing once the engine already names
    /// the Mac, and an apply through the governor waits its uncap window (or,
    /// wedged, never lands), so a terminal left at a departed viewer's grid
    /// stayed there. This drops the governor (and any change it staged) and
    /// applies the host's target directly; a resize happens only when the
    /// size differs. Only Size to My Window forces: app activation and
    /// keystrokes keep ``noteMacAction(surfaceID:)``.
    func sizeToMe(surfaceID: UUID) {
        noteMacAction(surfaceID: surfaceID)
        let controller = TerminalController.shared
        guard let host = controller.localSizingHostsBySurfaceID[surfaceID],
              !host.isDetached(host.macParticipantID) else { return }
        let reason = "terminal.size_to_me"
        controller.teardownMobileViewportGovernor(surfaceID: surfaceID)
        switch host.applyTarget {
        case .uncapped:
            // Direct, not governed: a fresh governor drops an uncap it never
            // capped, and a repeated clear also retries a font restore.
            _ = controller.performMobileViewportTarget(surfaceID: surfaceID, target: .uncapped, reason: reason)
        case let .grid(size):
            // A fresh governor applies the first cap at once and records it.
            controller.governMobileViewportTarget(
                surfaceID: surfaceID,
                target: .cap(columns: size.cols, rows: size.rows),
                immediate: true,
                reason: reason
            )
        }
        // The uncapped pane's grid can differ from the one last reported
        // (the font fit is restored): report it again.
        controller.localSizingMacViewportChanged(surfaceID: surfaceID)
    }

    #if DEBUG
    /// Runs the app-activation handler, as `didBecomeActiveNotification`
    /// does (`terminal_sizing.activate`).
    func debugAppDidBecomeActive() {
        focusedTerminalActivated()
    }
    #endif

    /// The user switched to this app: the terminal focused in its key window
    /// is where they are now.
    private func focusedTerminalActivated() {
        guard let window = NSApp.keyWindow, let surfaceID = Self.focusedTerminalID(in: window) else { return }
        #if DEBUG
        macActivations += 1
        #endif
        noteMacAction(surfaceID: surfaceID)
    }

    /// The terminal that holds the window's focus: its surface view or a view
    /// hosted in it (the find field), or its TextBox, which is laid out
    /// beside the hosted surface view, so only its panel knows it.
    private static func focusedTerminalID(in window: NSWindow) -> UUID? {
        guard let responder = window.firstResponder else { return nil }
        if let id = responder.cmuxTerminalFocusOwningGhosttyView()?.terminalSurface?.id { return id }
        guard let panel = AppDelegate.shared?.contextForMainWindow(window)?.tabManager.selectedTerminalPanel,
              panel.ownedFocusIntent(for: responder, in: window) != nil else { return nil }
        return panel.id
    }

    // MARK: - This Mac's user's selection

    /// This Mac's user selected a workspace: the terminals it shows (each
    /// pane's selected tab) are where they look now.
    func macUserSelected(workspace: Workspace?) {
        guard SupermuxLocalUserInput.isHandling, let workspace else { return }
        let panes = workspace.bonsplitController
        recordMacSelection(panes.allPaneIds.compactMap { pane in
            panes.selectedTab(inPane: pane).flatMap { workspace.panelIdFromSurfaceId($0.id) }
        })
    }

    /// This Mac's user selected a tab or focused a pane.
    func macUserSelected(panelID: UUID?) {
        guard SupermuxLocalUserInput.isHandling, let panelID else { return }
        recordMacSelection([panelID])
    }

    private func recordMacSelection(_ panelIDs: [UUID]) {
        let now = ProcessInfo.processInfo.systemUptime
        macSelections = macSelections.filter { now - $0.value <= Self.macSelectionWindow }
        for id in panelIDs { macSelections[id] = now }
    }

    /// A phone attached to, or started viewing, a terminal this Mac's user
    /// selected a moment ago: the phone follows the Mac's selection (its
    /// terminal view remounts on the pushed tab), so the user is at the Mac.
    /// Another Mac's mirror attaching or coming on screen is held the same
    /// way (a tab this Mac's user just opened shows in that mirror too), but
    /// never its explicit claim (``viewersReported``).
    /// The Mac pane's activity is noted after the phone's, so it stays the
    /// newest; typing on the phone still takes the grid. Only the Mac's own
    /// selection: a socket, automation or the phone's selection is not.
    /// The pane's activity is noted while the Visibility layer still marks
    /// it off screen (it decides once the pane shows), never against an
    /// override someone set by hand.
    private func keepMacSelection(_ host: inout LocalTerminalSizingHost, surfaceID: UUID) {
        guard let selectedAt = macSelections[surfaceID],
              ProcessInfo.processInfo.systemUptime - selectedAt <= Self.macSelectionWindow,
              let mac = host.state.participant(host.macParticipantID) else { return }
        guard mac.participant.countsOverride != false
                || SupermuxTerminalSizingVisibility.shared.marksOffScreen(surfaceID) else { return }
        host.noteActivity(host.macParticipantID)
    }

    /// A scroll on a Mac pane is its user's activity, as typing is: a wheel
    /// notch or the start of a gesture, never the momentum after it, which
    /// keeps arriving after the user let go.
    func macPaneScrolled(_ event: NSEvent, surfaceID: UUID) {
        guard event.momentumPhase.isEmpty, event.phase.isEmpty || event.phase == .began else { return }
        TerminalController.shared.noteLocalTerminalSizingActivity(surfaceID: surfaceID)
    }
}
