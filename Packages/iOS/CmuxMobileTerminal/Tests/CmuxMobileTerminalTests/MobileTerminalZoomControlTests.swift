#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

@Suite("Mobile terminal zoom controls", .serialized)
@MainActor
struct MobileTerminalZoomControlTests {
    @Test("built-in terminal font size is 12 points")
    func builtInDefaultSize() {
        #expect(MobileTerminalFontPreference.defaultSize == 12)
    }

    @Test("saved zoom becomes the default for newly mounted terminals")
    func savedDefaultPersists() throws {
        let suiteName = "CmuxMobileTerminalTests.MobileTerminalZoomControlTests.savedDefaultPersists"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preference = MobileTerminalZoomPreference(defaults: defaults)
        #expect(preference.resolvedFontSize == 12)

        preference.save(17)
        #expect(preference.resolvedFontSize == 17)
        #expect(MobileTerminalZoomPreference(defaults: defaults).resolvedFontSize == 17)

        preference.clear()
        #expect(preference.resolvedFontSize == 12)
        #expect(MobileTerminalZoomPreference(defaults: defaults).resolvedFontSize == 12)
    }

    @Test("every floating zoom button invokes its action")
    func floatingButtonsInvokeActions() throws {
        let overlay = MobileTerminalZoomControlOverlay()
        var interactions = 0
        var actions: [String] = []
        overlay.onInteraction = { interactions += 1 }
        overlay.onResetToDefault = { actions.append("reset") }
        overlay.onSaveAsDefault = { actions.append("save") }
        overlay.onRestoreBuiltIn = { actions.append("restore") }

        try invokeButton(
            titled: String(localized: "terminal.zoom.reset_to_default", defaultValue: "Reset to default"),
            in: overlay
        )
        try invokeButton(
            titled: String(localized: "terminal.zoom.set_as_default", defaultValue: "Set as default"),
            in: overlay
        )
        try invokeButton(
            titled: String(localized: "terminal.zoom.restore_built_in", defaultValue: "Restore built-in"),
            in: overlay
        )

        #expect(actions == ["reset", "save", "restore"])
        #expect(interactions == 3)
    }

    private func invokeButton(
        titled title: String,
        in overlay: MobileTerminalZoomControlOverlay
    ) throws {
        let control = try #require(button(titled: title, in: overlay))
        let actions = try #require(
            control.actions(forTarget: overlay, forControlEvent: .touchUpInside)
        )
        #expect(actions.count == 1)
        for action in actions {
            let selector = NSSelectorFromString(action)
            #expect(overlay.responds(to: selector))
            _ = overlay.perform(selector)
        }
    }

    private func button(titled title: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton,
           button.configuration?.title == title || button.title(for: .normal) == title {
            return button
        }
        for subview in view.subviews {
            if let match = button(titled: title, in: subview) {
                return match
            }
        }
        return nil
    }
}
#endif
