import AppKit
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
///   `view_appeared: true`, ``viewAppearedClientID``). Any other report that
///   repeats the same viewport is no activity: the phone sends one in answer
///   to every grid change, which would hand the grid back and forth.
///
/// On the Mac, typing, a paste and a focus click were already activity;
/// this class adds the app becoming active with a terminal focused. A pane
/// merely coming on screen is not: selecting a workspace on the phone
/// selects it on the Mac too, and would take the grid from the phone.
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
        if host.state.policy.mode == .latest {
            let appeared = viewAppearedClientID.map { LocalTerminalSizingHost.phoneParticipantID(clientID: $0) }
            for id in host.phoneParticipantIDs
            where id == appeared || Self.startedViewing(id, now: host.state, before: previous) {
                host.noteActivity(id)
            }
        }
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
    /// active with the terminal focused.
    func noteMacAction(surfaceID: UUID) {
        let enclosing = notingMacAction
        notingMacAction = true
        defer { notingMacAction = enclosing }
        TerminalController.shared.noteLocalTerminalSizingActivity(surfaceID: surfaceID)
    }

    /// The user switched to this app: the terminal focused in its key window
    /// is where they are now.
    private func focusedTerminalActivated() {
        guard let view = NSApp.keyWindow?.firstResponder as? GhosttyNSView,
              let surfaceID = view.terminalSurface?.id else { return }
        #if DEBUG
        macActivations += 1
        #endif
        noteMacAction(surfaceID: surfaceID)
    }
}
