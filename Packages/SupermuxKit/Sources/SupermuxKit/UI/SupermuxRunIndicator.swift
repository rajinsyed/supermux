public import SwiftUI

/// A small green play glyph shown on a workspace row while that workspace's
/// project run command is active, mirroring piggycode's `WorkspaceRunIndicator`.
///
/// Pure value view (no store), so it is safe to render inside the sidebar's row
/// `ForEach` under the snapshot-boundary rule.
public struct SupermuxRunIndicator: View {
    /// Creates a run indicator.
    public init() {}

    public var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(Color.green)
            .help(String(localized: "supermux.runIndicator.label", defaultValue: "Run command active"))
            .accessibilityLabel(String(localized: "supermux.runIndicator.label", defaultValue: "Run command active"))
    }
}
