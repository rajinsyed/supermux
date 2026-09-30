import CmuxMobileShell
import CmuxMobileShellModel

/// User actions emitted by ``TerminalPickerMenu`` without exposing mutable stores to its row subtree.
struct TerminalPickerMenuActions {
    let selectTerminal: (MobileTerminalPreview.ID) -> Void
    let selectMacSurface: (MobileSurfacePreview.ID) -> Void
    let createWorkspace: () -> Void
    let createTerminal: () -> Void
    /// A grouped section's action (``TerminalPickerMenuValue/sshTabLayout``):
    /// "Split Right" / "Split Down" on a tmux window, "New Tab" or a split
    /// on a cmux-tui screen. Receives the section id.
    var createSSHTab: (String, MobileSSHSectionAction) -> Void = { _, _ in }
    let openBrowser: () -> Void
    let selectBrowserStream: (String) -> Void
    let selectSimulatorStream: (String) -> Void
    // SUPERMUX:begin ios-pane-actions
    /// Defaulted so upstream call sites (and upstream tests) that predate the
    /// fork's simulator pane action compile unchanged.
    var createSimulator: () -> Void = {}
    // SUPERMUX:end ios-pane-actions
    let openTextSheet: () -> Void
    let copyDebugLogs: () -> Void
    let sendFeedback: () -> Void
}
