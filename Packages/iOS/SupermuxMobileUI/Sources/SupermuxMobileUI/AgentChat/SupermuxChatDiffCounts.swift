public import SwiftUI

/// The `+12 −3` pair used wherever a change is quantified.
///
/// Digits are monospaced so counts stay column-aligned down a file list, and
/// a zero side is omitted rather than shown as `+0` — an unchanged side is
/// noise.
public struct SupermuxChatDiffCounts: View {
    private let additions: Int?
    private let deletions: Int?

    @Environment(\.supermuxChatTheme) private var theme

    /// Creates a counts label.
    ///
    /// - Parameters:
    ///   - additions: Added lines, when known.
    ///   - deletions: Removed lines, when known.
    public init(additions: Int?, deletions: Int?) {
        self.additions = additions
        self.deletions = deletions
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let additions, additions > 0 {
                Text(verbatim: "+\(additions)")
                    .foregroundStyle(theme.diffAdded)
            }
            if let deletions, deletions > 0 {
                Text(verbatim: "−\(deletions)")
                    .foregroundStyle(theme.diffRemoved)
            }
        }
        .font(.supermuxChatFootnote(.medium))
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if let additions, additions > 0 {
            parts.append(String(
                localized: "supermux.chat.diff.additions.accessibility",
                defaultValue: "\(additions) added",
                bundle: .module
            ))
        }
        if let deletions, deletions > 0 {
            parts.append(String(
                localized: "supermux.chat.diff.deletions.accessibility",
                defaultValue: "\(deletions) removed",
                bundle: .module
            ))
        }
        return parts.joined(separator: ", ")
    }
}
