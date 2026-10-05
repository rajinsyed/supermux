import Foundation

/// The one rule for "is the hosting window visible enough to present a renderer".
///
/// `NSWindow.occlusionState` is the authoritative signal on a real display: a
/// miniaturized, fully covered, or inactive-Space window drops the `.visible`
/// bit and the renderer is released. On a virtual/headless display (the CI
/// display-churn harness runs the app on a `CGVirtualDisplay`) AppKit never
/// raises `.visible` for a window that is nevertheless ordered in and drawing,
/// so gating presentation on that bit alone leaves the terminal at zero
/// presents forever. Until a window has reported `.visible` at least once, its
/// ordinary on-screen state is trusted instead; a key window is always visible.
public struct TerminalRendererWindowVisibility: Sendable {
    public let occlusionVisible: Bool
    public let windowHasReportedVisible: Bool
    public let isWindowVisible: Bool
    public let isMiniaturized: Bool
    public let isOnActiveSpace: Bool
    public let isKeyWindow: Bool

    public init(
        occlusionVisible: Bool,
        windowHasReportedVisible: Bool,
        isWindowVisible: Bool,
        isMiniaturized: Bool,
        isOnActiveSpace: Bool,
        isKeyWindow: Bool
    ) {
        self.occlusionVisible = occlusionVisible
        self.windowHasReportedVisible = windowHasReportedVisible
        self.isWindowVisible = isWindowVisible
        self.isMiniaturized = isMiniaturized
        self.isOnActiveSpace = isOnActiveSpace
        self.isKeyWindow = isKeyWindow
    }

    public var isVisible: Bool {
        // SUPERMUX:begin renderer-key-window-honors-occlusion (upstream: a key window always presents, before the occlusion verdict)
        // A locked or sleeping display keeps the window key while dropping
        // `.visible`, so the key exception kept every visible terminal
        // drawing, its display link running, for as long as nobody looked.
        // The key window still counts while occlusion is untrusted.
        if occlusionVisible { return true }
        // Occlusion has been trustworthy for this window: honor its verdict.
        if windowHasReportedVisible { return false }
        if isKeyWindow { return true }
        // SUPERMUX:end renderer-key-window-honors-occlusion
        return isWindowVisible && !isMiniaturized && isOnActiveSpace
    }
}
