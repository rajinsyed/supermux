public import SwiftUI

/// One `#1234` chip in the Changes panel header — one per open pull request
/// on the workspace's branch. Clicking it opens ``SupermuxPullRequestViewerView``
/// for that PR; clicking the selected chip again returns to the changes list.
///
/// Holds only a value and a closure, so the header can hand it snapshots.
public struct SupermuxPullRequestHeaderButton: View {
    private let pullRequest: SupermuxPullRequestSummary
    private let isSelected: Bool
    private let action: () -> Void

    /// Creates a chip.
    /// - Parameters:
    ///   - pullRequest: The PR to represent.
    ///   - isSelected: Whether the viewer is showing this PR (filled chip).
    ///   - action: Runs on click.
    public init(pullRequest: SupermuxPullRequestSummary, isSelected: Bool, action: @escaping () -> Void) {
        self.pullRequest = pullRequest
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        let tint = pullRequest.isDraft ? Color.secondary : SupermuxPullRequest.Status.open.supermuxTint
        Button(action: action) {
            HStack(spacing: 3) {
                SupermuxPullRequestStatusIcon(status: .open, size: 10)
                Text("#\(pullRequest.number)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(isSelected ? Color.white : tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(isSelected ? 0.9 : 0.16)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var helpText: String {
        let title = pullRequest.title.isEmpty ? "#\(pullRequest.number)" : "#\(pullRequest.number) \(pullRequest.title)"
        return isSelected
            ? String(localized: "supermux.pullRequest.button.close.help", defaultValue: "Back to changes")
            : String(localized: "supermux.pullRequest.button.open.help", defaultValue: "Show pull request \(title)")
    }
}
