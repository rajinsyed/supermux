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
///
/// The distance is exact when the replay holds what the mirror held. A mirror
/// that attached while output flowed can hold some of it twice until the
/// re-capture that confirms its first replay; a view below those rows lands
/// that many rows off.
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
    /// the noted view, unless its user scrolled or typed since the replay.
    func restore(on surface: TerminalSurface?) async {
        guard let surface else { return }
        await surface.supermuxRemoteOutputParsed()
        surface.hostedView.supermuxScrollBack(rowsBelowViewport: rowsBelowViewport)
    }
}

extension GhosttySurfaceScrollView {
    /// Shows the rows that end `rowsBelowViewport` rows above the live bottom.
    ///
    /// Only while the view is where the replay left it: still reviewing (a
    /// keystroke after the replay follows the output again) and at the live
    /// bottom (a scroll after the replay is the user's own). A replay with no
    /// history leaves nothing to read back: the view follows the output.
    fileprivate func supermuxScrollBack(rowsBelowViewport: Int) {
        guard scrollbackViewportIntent.isReviewingScrollback,
              let geometry = surfaceView.authoritativeScrollbarGeometry(),
              geometry.scrollbar.isAtBottom else { return }
        let totalRows = Int(clamping: geometry.scrollbar.total)
        let lastTopRow = totalRows - min(totalRows, Int(clamping: geometry.scrollbar.len))
        guard lastTopRow > 0 else {
            prepareExplicitViewportRestore(isAtBottom: true)
            synchronizeScrollView(forceViewportSync: true)
            return
        }
        let topRow = max(0, lastTopRow - rowsBelowViewport)
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
