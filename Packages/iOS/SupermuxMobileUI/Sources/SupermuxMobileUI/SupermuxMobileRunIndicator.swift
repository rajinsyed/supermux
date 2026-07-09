import SwiftUI

/// The small green play glyph shown on a nested workspace row while that
/// workspace hosts its project's active run command — the phone twin of the
/// Mac's `SupermuxRunIndicator` (piggycode's `WorkspaceRunIndicator`).
///
/// Pure value view (no store), safe inside the list's row `ForEach` under
/// the snapshot-boundary rule.
struct SupermuxMobileRunIndicator: View {
    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.green)
            .accessibilityLabel(String(
                localized: "supermux.runIndicator.label",
                defaultValue: "Run command active",
                bundle: .module
            ))
    }
}
