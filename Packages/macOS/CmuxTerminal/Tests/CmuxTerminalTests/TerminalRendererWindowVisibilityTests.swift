import Testing
@testable import CmuxTerminal

/// The presentation gate must never leave an on-screen window unpresented just
/// because AppKit never reported `.visible` for it (virtual/headless displays),
/// while a window whose occlusion state has proven trustworthy still releases
/// when it is miniaturized, covered, or on an inactive Space.
struct TerminalRendererWindowVisibilityTests {
    private func visible(
        occlusion: Bool = false,
        reported: Bool = false,
        onScreen: Bool = true,
        miniaturized: Bool = false,
        activeSpace: Bool = true,
        key: Bool = false
    ) -> Bool {
        TerminalRendererWindowVisibility(
            occlusionVisible: occlusion,
            windowHasReportedVisible: reported,
            isWindowVisible: onScreen,
            isMiniaturized: miniaturized,
            isOnActiveSpace: activeSpace,
            isKeyWindow: key
        ).isVisible
    }

    @Test func onScreenWindowThatNeverReportedVisiblePresents() {
        #expect(visible())
    }

    // SUPERMUX:begin renderer-key-window-honors-occlusion (upstream: `keyWindowAlwaysPresents` expected a key window to present after occlusion said hidden)
    @Test func keyWindowPresentsUntilOcclusionIsTrusted() {
        #expect(visible(onScreen: false, key: true))
        #expect(visible(occlusion: true, reported: true, key: true))
        // A locked or sleeping display: still key, occlusion trusted and hidden.
        #expect(!visible(reported: true, key: true))
    }
    // SUPERMUX:end renderer-key-window-honors-occlusion

    @Test func occlusionVerdictWinsOnceTheWindowHasReportedVisible() {
        #expect(visible(occlusion: true, reported: true))
        #expect(!visible(occlusion: false, reported: true))
    }

    @Test func untrustedOcclusionStillHonorsMiniaturizedHiddenAndInactiveSpace() {
        #expect(!visible(miniaturized: true))
        #expect(!visible(onScreen: false))
        #expect(!visible(activeSpace: false))
    }
}
