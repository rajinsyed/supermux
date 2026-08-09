import Testing

@testable import CmuxMobileShell

@Suite("Alternate-screen direct-apply policy")
struct TerminalAltScrollDirectApplyPolicyTests {
    @Test("deltas inside the scroll window apply directly")
    func deltasInsideWindowApplyDirectly() {
        #expect(TerminalAltScrollDirectApplyPolicy.shouldApplyDirectly(
            isFullFrame: false,
            lastScrollInputAt: 100.0,
            now: 100.3
        ))
        #expect(TerminalAltScrollDirectApplyPolicy.shouldApplyDirectly(
            isFullFrame: false,
            lastScrollInputAt: 100.0,
            now: 100.79
        ))
    }

    @Test("deltas outside the window return to verified application")
    func deltasOutsideWindowStayVerified() {
        #expect(!TerminalAltScrollDirectApplyPolicy.shouldApplyDirectly(
            isFullFrame: false,
            lastScrollInputAt: 100.0,
            now: 100.81
        ))
        #expect(!TerminalAltScrollDirectApplyPolicy.shouldApplyDirectly(
            isFullFrame: false,
            lastScrollInputAt: nil,
            now: 100.0
        ))
    }

    @Test("full frames always verify, even mid-gesture")
    func fullFramesAlwaysVerify() {
        #expect(!TerminalAltScrollDirectApplyPolicy.shouldApplyDirectly(
            isFullFrame: true,
            lastScrollInputAt: 100.0,
            now: 100.1
        ))
    }

    @Test("a backwards clock never opens the direct window")
    func backwardsClockFailsClosed() {
        #expect(!TerminalAltScrollDirectApplyPolicy.shouldApplyDirectly(
            isFullFrame: false,
            lastScrollInputAt: 200.0,
            now: 199.0
        ))
    }
}
