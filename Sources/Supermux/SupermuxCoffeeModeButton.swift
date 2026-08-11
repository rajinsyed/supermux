import AppKit
import CmuxAppKitSupportUI
import SupermuxKit
import SwiftUI

extension SupermuxComposition {
    /// App-wide Coffee Mode model: one set of power assertions shared by every
    /// window's sidebar footer, so the toggle reads the same in all windows.
    static let coffeeModeModel = SupermuxCoffeeModeModel(
        assertion: SupermuxKeepAwakeAssertion(),
        defaults: .standard
    )

    /// Forces the model into existence at launch so a persisted "on" state is
    /// re-applied. Swift `static let` is lazy, and the button below is the only
    /// other reference — but presentation modes that hide the sidebar footer
    /// never construct it, which would leave a Mac the user had set to stay
    /// awake silently sleeping after a relaunch. Called from the
    /// `coffee-mode-restore` touchpoint in `AppDelegate.swift`.
    static func restoreCoffeeMode() {
        _ = coffeeModeModel
    }
}

/// The sidebar-footer Coffee Mode toggle, mounted beside the fork's usage
/// buttons and upstream's help "?" button (see the `sidebar-coffee-mode-button`
/// touchpoint in `ContentView.swift`).
///
/// Keeps the Mac from idle-sleeping so long-running agents are not cut off.
/// Unlike Sleepy Mode—which keeps the display awake behind a full-screen
/// screensaver—Coffee Mode lets the display turn off normally.
///
/// Purely additive: upstream's help button and the fork's usage buttons all
/// keep rendering untouched next to it.
struct SupermuxCoffeeModeButton: View {
    private let buttonSize = SidebarFooterButtonMetrics.buttonSize

    var body: some View {
        let model = SupermuxComposition.coffeeModeModel
        Button {
            model.toggle()
        } label: {
            SupermuxCoffeeModeIcon(
                isEnabled: model.isEnabled,
                isDegraded: model.coverage.isDegraded,
                pointSize: SidebarFooterButtonMetrics.helpIconSize - 1
            )
            .frame(width: buttonSize, height: buttonSize, alignment: .center)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
        .accessibilityElement(children: .ignore)
        .safeHelp(model.coverage.tooltip)
        .accessibilityLabel(String(
            localized: "supermux.coffee.button",
            defaultValue: "Coffee Mode"
        ))
        .accessibilityValue(model.isEnabled
            ? String(localized: "supermux.coffee.state.on", defaultValue: "On")
            : String(localized: "supermux.coffee.state.off", defaultValue: "Off"))
        .accessibilityAddTraits(model.isEnabled ? [.isSelected] : [])
        .accessibilityIdentifier("SupermuxCoffeeModeButton")
    }
}

/// The mug glyph. Off is a hairline outline in the same secondary grey as its
/// neighbours; on is the filled mug in the accent colour with a soft accent
/// wash behind it, so enabled state reads at a glance without a badge or dot.
private struct SupermuxCoffeeModeIcon: View {
    let isEnabled: Bool
    let isDegraded: Bool
    let pointSize: CGFloat

    private var symbolName: String {
        isEnabled ? "cup.and.saucer.fill" : "cup.and.saucer"
    }

    private var foreground: Color {
        // Degraded means macOS refused the assertions — show the mode is not
        // delivering rather than lighting up as if it were.
        if isDegraded { return Color(nsColor: .systemOrange) }
        return isEnabled ? cmuxAccentColor() : Color(nsColor: .secondaryLabelColor)
    }

    var body: some View {
        Image(systemName: symbolName)
            .contentTransition(.symbolEffect(.replace))
            .font(.system(size: pointSize, weight: .medium))
            .foregroundStyle(foreground)
            .frame(
                width: SidebarFooterButtonMetrics.buttonSize,
                height: SidebarFooterButtonMetrics.buttonSize
            )
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(foreground.opacity(isEnabled ? 0.14 : 0))
            )
            .animation(.easeOut(duration: 0.16), value: isEnabled)
            .animation(.easeOut(duration: 0.16), value: isDegraded)
    }
}
