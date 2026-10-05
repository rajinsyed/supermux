// SUPERMUX:begin sizing-phone-viewer (the phone that views a terminal owns its grid in Auto — see SUPERMUX-TOUCHPOINTS.md)
#if canImport(UIKit)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileTerminal
import UIKit

/// The flags a phone viewport report carries so the Mac's Auto mode hands the
/// grid to the device the user is viewing the terminal from.
extension GhosttySurfaceRepresentable.Coordinator {
    /// Adds this mount's pending flags to the report about to be sent,
    /// preparing it on the spot when no preparation exists yet.
    /// - Parameters:
    ///   - preparation: The report's preparation, if one was made at output start.
    ///   - report: The scheduled report.
    ///   - store: The shell store.
    /// - Returns: The preparation to send, or `nil` when the terminal has no route.
    func supermuxFlagViewportReport(
        _ preparation: MobileTerminalViewportPreparation?,
        report: TerminalViewportReportScheduler.Report,
        store: CMUXMobileShellStore
    ) -> MobileTerminalViewportPreparation? {
        // A hidden terminal is not being viewed: its report never claims it.
        let viewAppeared = viewAppearedReportPending && terminalSurfaceShown
        let countsOverride = pendingCountsOverrideChange
        guard viewAppeared || countsOverride != .unchanged else { return preparation }
        var flagged = preparation ?? store.prepareTerminalViewport(
            surfaceID: surfaceID,
            columns: report.columns,
            rows: report.rows
        )
        flagged?.viewAppeared = viewAppeared
        flagged?.countsOverride = countsOverride
        return flagged
    }

    /// A report reached the Mac (it answered with a grid): its flags are spent.
    /// A report dropped offline, cancelled or superseded keeps them pending,
    /// so the next report carries them.
    /// - Parameter preparation: The delivered report's preparation.
    func supermuxViewportReportDelivered(_ preparation: MobileTerminalViewportPreparation) {
        if preparation.viewAppeared { viewAppearedReportPending = false }
        if preparation.countsOverride == .clear { countsRestorePending = false }
    }

    // MARK: Hidden under another tab

    /// The workspace detail shows this terminal, or hides it (still mounted)
    /// under a browser, stream, Simulator or Mac-surface tab.
    ///
    /// While hidden the phone does not count toward the size: its reports
    /// carry `counts_override: false`, unless the user already turned "Counts
    /// toward size" off. Shown again, the next report clears the override the
    /// phone set and says `view_appeared`, so the viewing phone takes the grid
    /// back. The viewport lease and the output stream are untouched.
    /// - Parameter shown: Whether the terminal is the shown tab.
    func supermuxSetTerminalSurfaceShown(_ shown: Bool) {
        guard shown != terminalSurfaceShown else { return }
        terminalSurfaceShown = shown
        if shown {
            if phoneHidesCounts {
                phoneHidesCounts = false
                countsRestorePending = true
            }
            viewAppearedReportPending = true
        } else {
            // A `false` the phone set and has not cleared yet is its own.
            let userTurnedCountsOff = !countsRestorePending
                && store?.terminalSizingPresentation(for: surfaceID)?
                    .selfParticipant?.participant.countsOverride == false
            countsRestorePending = false
            guard !userTurnedCountsOff else { return }
            phoneHidesCounts = true
        }
        guard viewportReportScheduler != nil else { return }
        surfaceView?.requestViewportReportForMount()
    }

    /// The `counts_override` change this mount's next report carries.
    private var pendingCountsOverrideChange: MobileTerminalCountsOverrideChange {
        if phoneHidesCounts { return .set(false) }
        if countsRestorePending { return .clear }
        return .unchanged
    }
}
#endif
// SUPERMUX:end sizing-phone-viewer
