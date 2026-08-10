import Testing

@testable import SupermuxMobileUI

/// The phone's root chrome — the list's navigation-bar items, the tab bar, and
/// the compose button — used to be gated purely on "is the navigation path
/// empty". That is true at the wrong moment for an edge-swipe back: UIKit
/// reveals the root list immediately but `NavigationStack` only writes the
/// emptied path once the gesture commits, so every one of those controls
/// blinked in a beat after the list was already on screen.
@Suite("Compact root chrome visibility")
struct SupermuxCompactRootChromeTests {
    @Test("the root list shows its chrome")
    func rootShowsChrome() {
        let chrome = SupermuxCompactRootChrome()
        #expect(chrome.isVisible(pathIsEmpty: true))
    }

    @Test("a pushed workspace hides it")
    func pushedWorkspaceHidesChrome() {
        let chrome = SupermuxCompactRootChrome()
        #expect(!chrome.isVisible(pathIsEmpty: false))
    }

    /// The regression itself: mid-swipe the path still holds the workspace.
    @Test("an in-flight swipe back shows it before the path empties")
    func interactivePopShowsChromeBeforePathEmpties() {
        var chrome = SupermuxCompactRootChrome()
        chrome.interactivePopBegan()
        #expect(chrome.isVisible(pathIsEmpty: false))
    }

    /// Releasing short of the threshold puts the workspace back. The chrome has
    /// to go with it, or the detail is left wearing the list's toolbar.
    @Test("a cancelled swipe back hides it again")
    func rolledBackInteractivePopHidesChrome() {
        var chrome = SupermuxCompactRootChrome()
        chrome.interactivePopBegan()
        chrome.interactivePopRolledBack()
        #expect(!chrome.isVisible(pathIsEmpty: false))
    }

    /// A committed swipe deliberately does NOT clear the flag — clearing it
    /// while the pop animates would re-hide what the gesture just revealed. The
    /// path change is what retires it.
    @Test("a committed swipe keeps it shown until the path takes over")
    func committedInteractivePopKeepsChromeUntilPathChange() {
        var chrome = SupermuxCompactRootChrome()
        chrome.interactivePopBegan()
        #expect(chrome.isVisible(pathIsEmpty: false))
        chrome.navigationPathChanged()
        #expect(chrome.isVisible(pathIsEmpty: true))
    }

    /// Without this, a swipe back followed by opening another workspace would
    /// leave the list's toolbar and tab bar on top of the new detail.
    @Test("the next push after a swipe back hides it again")
    func pushAfterInteractivePopHidesChrome() {
        var chrome = SupermuxCompactRootChrome()
        chrome.interactivePopBegan()
        chrome.navigationPathChanged()
        #expect(!chrome.isVisible(pathIsEmpty: false))
    }
}
