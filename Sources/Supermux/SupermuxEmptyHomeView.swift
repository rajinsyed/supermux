import SwiftUI

/// Filling for the main content area when a window has no open workspaces.
///
/// Supermux keeps the window open as a "home" when the last tab is closed (the
/// `keep-window-on-last-close` touchpoint in `TabManager`), so the Projects
/// sidebar stays available to launch from. cmux otherwise renders nothing here,
/// because upstream never reaches a zero-workspace window. This quiet hint tells
/// the user how to get going again; it is non-interactive (the sidebar Projects
/// section and the `+` button are the actual entry points).
struct SupermuxEmptyHomeView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(String(
                localized: "supermux.emptyHome.title",
                defaultValue: "No open tabs"
            ))
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)
            Text(String(
                localized: "supermux.emptyHome.subtitle",
                defaultValue: "Double-click a project in the sidebar to start a workspace."
            ))
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
