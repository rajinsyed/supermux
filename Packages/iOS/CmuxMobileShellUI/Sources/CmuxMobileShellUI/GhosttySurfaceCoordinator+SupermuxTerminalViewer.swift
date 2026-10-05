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
        guard viewAppearedReportPending else { return preparation }
        var flagged = preparation ?? store.prepareTerminalViewport(
            surfaceID: surfaceID,
            columns: report.columns,
            rows: report.rows
        )
        flagged?.viewAppeared = true
        return flagged
    }

    /// A report reached the Mac (it answered with a grid): its flags are spent.
    /// A report dropped offline, cancelled or superseded keeps them pending,
    /// so the next report carries them.
    /// - Parameter preparation: The delivered report's preparation.
    func supermuxViewportReportDelivered(_ preparation: MobileTerminalViewportPreparation) {
        if preparation.viewAppeared { viewAppearedReportPending = false }
    }
}
#endif
// SUPERMUX:end sizing-phone-viewer
