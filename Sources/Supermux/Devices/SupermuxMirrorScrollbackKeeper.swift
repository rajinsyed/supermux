import CmuxTerminal
import CmuxTerminalCore

/// Keeps a device mirror's scrollback where its user was reading it across a
/// full replay.
///
/// A full replay (`ESC c`, `CSI 3 J`, then the other Mac's screen and its
/// history) rebuilds the mirror's terminal at the live bottom. Replays come on
/// their own: the confirmation re-capture once output goes quiet, every grid
/// change, a reconnect that cannot resume. Reading back through a mirror's
/// output therefore jumped to the bottom at random. When its user was reading
/// scrollback, the keeper notes how many rows sat below the view and, once the
/// replay is parsed, scrolls back to as many rows above the new bottom.
@MainActor
struct SupermuxMirrorScrollbackKeeper {
    private let rowsBelowViewport: Int

    /// Notes the view of `surface`; nil when it follows its output.
    init?(surface: TerminalSurface?) {
        guard let scrollView = surface?.hostedView,
              scrollView.scrollbackViewportIntent.isReviewingScrollback,
              let scrollbar = scrollView.surfaceView.authoritativeScrollbarGeometry()?.scrollbar,
              let anchor = TerminalScrollbackViewportAnchor(scrollbar: scrollbar),
              anchor.rowsBelowViewport > 0 else { return nil }
        rowsBelowViewport = anchor.rowsBelowViewport
    }

    /// Once the output handed to `surface` so far is parsed, scrolls back to
    /// the noted view, unless its user went back to the bottom meanwhile.
    func restore(on surface: TerminalSurface?) async {
        guard let surface else { return }
        await surface.supermuxRemoteOutputParsed()
        surface.hostedView.supermuxScrollBack(rowsBelowViewport: rowsBelowViewport)
    }
}

extension GhosttySurfaceScrollView {
    /// Shows the rows that end `rowsBelowViewport` rows above the live bottom,
    /// while the view still reviews scrollback.
    fileprivate func supermuxScrollBack(rowsBelowViewport: Int) {
        guard scrollbackViewportIntent.isReviewingScrollback,
              let geometry = surfaceView.authoritativeScrollbarGeometry() else { return }
        let totalRows = Int(clamping: geometry.scrollbar.total)
        let visibleRows = min(totalRows, Int(clamping: geometry.scrollbar.len))
        let topRow = max(0, totalRows - visibleRows - rowsBelowViewport)
        let previousIntent = prepareExplicitViewportRestore(isAtBottom: false)
        guard let restored = surfaceView.scrollToRow(
            topRow,
            ifRowSpaceRevisionMatches: geometry.rowSpaceRevision
        ) else {
            rollbackExplicitViewportRestore(to: previousIntent)
            return
        }
        surfaceView.scrollbar = restored.scrollbar
        synchronizeJumpToBottomIndicator()
        synchronizeScrollView(forceViewportSync: true)
    }
}
