import SupermuxMobileKit
public import SwiftUI

/// The workspace list's usage-gauge toolbar button — the phone's twin of the
/// Mac sidebar footer button (touchpoint #146).
///
/// The ring fills to the tightest Claude/Codex limit and tapping it presents
/// ``SupermuxUsageScreen``. Renders nothing unless the host advertises
/// `supermux.usage.v1`, so a fork phone paired with an upstream cmux Mac
/// shows exactly upstream's toolbar.
///
/// Deliberately owns NO session state. The gauge sits in the list's
/// `showsNavigationToolbar` branch, which is torn down on every navigation
/// push; a store held here would lose its snapshot and restart polling every
/// time you opened a workspace. The session lives in
/// ``SupermuxUsageSectionModel`` on the stable list view instead, and this
/// button just renders it.
public struct SupermuxUsageToolbarButton: View {
    private let model: SupermuxUsageSectionModel

    @State private var isPresented = false

    /// Creates the toolbar button.
    /// - Parameter model: The list-owned usage session (see
    ///   ``SwiftUICore/View/supermuxUsageDriver(model:connection:)``).
    public init(model: SupermuxUsageSectionModel) {
        self.model = model
    }

    public var body: some View {
        if model.showsButton {
            Button {
                isPresented = true
            } label: {
                SupermuxUsageGauge(window: model.tightestWindow)
            }
            .accessibilityLabel(String(
                localized: "supermux.usage.title",
                defaultValue: "Usage Limits",
                bundle: .module
            ))
            .accessibilityIdentifier("SupermuxUsageToolbarButton")
            // The sheet renders the SAME session the gauge does: one store
            // means the ring and the sheet can never show different numbers,
            // and presenting adds no second poll loop.
            .sheet(isPresented: $isPresented) {
                SupermuxUsageScreen(store: model.store)
            }
        }
    }
}

/// Pure visibility logic for the usage entry point, kept off the view so the
/// capability gate is package-unit-testable (UI-02 for this mount).
/// lint:allow namespace-enum — stateless capability-gate predicate kept off the view so the mount's visibility rule is package-unit-testable.
public enum SupermuxUsageEntry {
    /// Whether the toolbar gauge shows: a live connection whose host
    /// advertises `supermux.usage.v1`.
    /// - Parameter hostCapabilities: The connected host's raw capability
    ///   strings, or `nil` while disconnected.
    public static func showsButton(hostCapabilities: Set<String>?) -> Bool {
        guard let hostCapabilities else { return false }
        return SupermuxMobileCapabilities(hostCapabilities: hostCapabilities).supportsUsage
    }
}
