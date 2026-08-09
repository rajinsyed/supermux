import CmuxAppKitSupportUI
import SupermuxKit
import SwiftUI

extension SupermuxComposition {
    /// App-wide usage-analytics model: one scan cache and one history shared
    /// by every window's sidebar footer button.
    static let usageAnalyticsModel = SupermuxUsageAnalyticsModel()
}

/// The sidebar-footer analytics button, mounted beside the usage-limits gauge
/// (see the `sidebar-usage-analytics-button` touchpoint in `ContentView.swift`).
///
/// Where the gauge answers "how much of my quota is left", this answers "what
/// have I spent" — token and cost history across Claude Code and Codex, read
/// from their local session logs. Purely additive; upstream's help button and
/// the fork's limits button both keep rendering untouched.
struct SupermuxUsageAnalyticsMenuButton: View {
    @State private var isPopoverPresented = false

    private let buttonSize = SidebarFooterButtonMetrics.buttonSize
    private let title = String(localized: "supermux.analytics.button", defaultValue: "Usage Analytics")

    var body: some View {
        @Bindable var model = SupermuxComposition.usageAnalyticsModel
        Button {
            isPopoverPresented.toggle()
        } label: {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: SidebarFooterButtonMetrics.helpIconSize - 3, weight: .medium))
                .frame(width: buttonSize, height: buttonSize, alignment: .center)
        }
        .buttonStyle(SidebarFooterIconButtonStyle())
        .frame(width: buttonSize, height: buttonSize, alignment: .center)
        .background(ArrowlessPopoverAnchor(
            isPresented: $isPopoverPresented,
            preferredEdge: .maxY,
            detachedGap: 4
        ) {
            SupermuxUsageAnalyticsPopoverView(
                report: model.report,
                isScanning: model.isScanning,
                scanProgress: model.scanProgress,
                missingProviders: model.snapshot.missingProviders,
                generatedAt: model.lastScanFinishedAt,
                selectedRange: $model.selectedRange,
                onRefresh: {
                    Task { await SupermuxComposition.usageAnalyticsModel.refresh(force: true) }
                }
            )
        })
        // Scanning is lazy: gigabytes of session logs are only read once the
        // user actually asks to see the numbers, then throttled by the model.
        .onChange(of: isPopoverPresented) { _, isPresented in
            guard isPresented else { return }
            Task { await SupermuxComposition.usageAnalyticsModel.refresh() }
        }
        .accessibilityElement(children: .ignore)
        .safeHelp(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("SupermuxUsageAnalyticsMenuButton")
    }
}
