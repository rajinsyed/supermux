import CmuxAppKitSupportUI
import SupermuxKit
import SwiftUI

extension SupermuxComposition {
    /// App-wide usage tracker model: one poll loop and one pair of provider
    /// snapshots shared by every window's sidebar footer button.
    static let usageModel = SupermuxUsageModel()
}

/// The sidebar-footer usage button, mounted alongside cmux's help "?" button
/// (see the `sidebar-usage-button` touchpoint in `ContentView.swift`).
///
/// The icon is a tiny gauge ring filled to the tightest Claude/Codex limit;
/// clicking opens the unified usage popover. Purely additive — the upstream
/// help button keeps rendering untouched next to it.
struct SupermuxUsageMenuButton: View {
    @State private var isPopoverPresented = false
    /// Whether this window is on screen: the shared poll loop polls only
    /// while some window showing the button is.
    @StateObject private var windowVisibility = SupermuxWindowVisibility()

    private let buttonSize = SidebarFooterButtonMetrics.buttonSize
    private let title = String(localized: "supermux.usage.button", defaultValue: "Usage Limits")

    var body: some View {
        let model = SupermuxComposition.usageModel
        let visibility = windowVisibility
        Button {
            isPopoverPresented.toggle()
        } label: {
            SupermuxUsageGaugeIcon(
                window: model.tightestWindow,
                pointSize: SidebarFooterButtonMetrics.helpIconSize - 2
            )
            .frame(width: buttonSize, height: buttonSize, alignment: .center)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            SupermuxUsagePopoverView(
                model: SupermuxComposition.usageModel,
                onRefresh: {
                    await SupermuxComposition.usageModel.refresh()
                },
                onSwitchAccount: { slot in
                    Task { await SupermuxComposition.usageModel.switchClaudeAccount(toSlot: slot) }
                },
                onSwitchToBest: {
                    Task { await SupermuxComposition.usageModel.switchClaudeToBest() }
                },
                onSetAccountEnabled: { slot, enabled in
                    Task { await SupermuxComposition.usageModel.setClaudeAccountEnabled(enabled, slot: slot) }
                }
            )
        })
        // Keeps the shared poll loop alive while the button is mounted (one
        // loop across windows); it polls only while one of their windows is
        // on screen, and refreshes as soon as one comes back.
        .task {
            await SupermuxComposition.usageModel.runPollLoop(isObserved: { visibility.isOnScreen })
        }
        .onChange(of: windowVisibility.isOnScreen) { _, _ in
            SupermuxComposition.usageModel.observationDidChange()
        }
        .supermuxTracksWindowVisibility(windowVisibility)
        // Opening the popover asks for a refresh; the model's shared floor
        // (minimumRefreshInterval) makes this a no-op when data is recent.
        .onChange(of: isPopoverPresented) { _, isPresented in
            guard isPresented else { return }
            Task { await SupermuxComposition.usageModel.refresh() }
        }
        .accessibilityElement(children: .ignore)
        .safeHelp(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("SupermuxUsageMenuButton")
    }
}
