public import SwiftUI

/// The clickable pull-request badge shown on sidebar worktree and nested
/// workspace rows: a real git-pull-request glyph plus the PR number, tinted by
/// the PR's lifecycle state (green open, purple merged, red closed).
///
/// State is conveyed by the glyph shape and color, so the badge stays compact
/// (no state word); the state word lives in the accessibility label for
/// VoiceOver. Used by both ``SupermuxOpenWorkspaceRowView`` and
/// ``SupermuxWorktreeRowView`` so the badge looks identical wherever a worktree
/// appears. Holds only a value and an open closure, so it crosses the sidebar
/// snapshot boundary cleanly.
public struct SupermuxPullRequestBadge: View {
    private let pullRequest: SupermuxPullRequest
    private let fontScale: CGFloat
    private let onOpen: (URL) -> Void

    /// Creates a badge.
    /// - Parameters:
    ///   - pullRequest: The pull request to display.
    ///   - fontScale: Sidebar font scale (cmux's `sidebar-font-size`); `1` at the
    ///     default size, multiplied into the badge's text and icon.
    ///   - onOpen: Opens the PR's URL when the badge is clicked.
    public init(
        pullRequest: SupermuxPullRequest,
        fontScale: CGFloat = 1,
        onOpen: @escaping (URL) -> Void
    ) {
        self.pullRequest = pullRequest
        self.fontScale = fontScale
        self.onOpen = onOpen
    }

    public var body: some View {
        Button {
            onOpen(pullRequest.url)
        } label: {
            HStack(spacing: 2 * fontScale) {
                SupermuxPullRequestStatusIcon(status: pullRequest.status, size: 11 * fontScale)
                Text(verbatim: "#\(pullRequest.number)")
                    .font(.system(size: 9.5 * fontScale, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(pullRequest.status.supermuxTint)
            .opacity(pullRequest.isStale ? 0.5 : 1)
            .padding(.horizontal, 4 * fontScale)
            .padding(.vertical, 1.5 * fontScale)
            .background(
                Capsule(style: .continuous)
                    .fill(pullRequest.status.supermuxTint.opacity(0.16))
            )
        }
        .buttonStyle(.plain)
        .help(pullRequest.status.supermuxOpenHelp(number: pullRequest.number))
        .accessibilityLabel(pullRequest.status.supermuxAccessibilityLabel(number: pullRequest.number))
        .accessibilityAddTraits(.isButton)
    }
}

/// The status icon: a real git-pull-request glyph for open/merged (matching
/// cmux's own sidebar PR icons) and `xmark.circle` for closed. Inherits the
/// surrounding `foregroundStyle`, so the badge's state tint colors it.
struct SupermuxPullRequestStatusIcon: View {
    let status: SupermuxPullRequest.Status
    let size: CGFloat

    var body: some View {
        switch status {
        case .open:
            SupermuxPullRequestGlyph(kind: .open, size: size)
        case .merged:
            SupermuxPullRequestGlyph(kind: .merged, size: size)
        case .closed:
            Image(systemName: "xmark.circle")
                .font(.system(size: size * 0.66, weight: .semibold))
                .frame(width: size, height: size)
        }
    }
}

/// Draws the GitHub-style git-pull-request glyph (two branch nodes joined to a
/// third) using the same path geometry as cmux's sidebar PR icons, scaled from
/// its native 13-unit canvas to `size`. Strokes with `.foreground`, so the
/// badge's `foregroundStyle` tint colors it.
struct SupermuxPullRequestGlyph: View {
    /// Which PR glyph to draw.
    enum Kind { case open, merged }

    let kind: Kind
    let size: CGFloat

    private static let canvas: CGFloat = 13
    private static let nodeDiameter: CGFloat = 3
    private static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)

    var body: some View {
        ZStack {
            branches
            nodes
        }
        .frame(width: Self.canvas, height: Self.canvas)
        .scaleEffect(size / Self.canvas)
        .frame(width: size, height: size)
    }

    private var branches: some View {
        Path { path in
            switch kind {
            case .open:
                path.move(to: CGPoint(x: 3.0, y: 4.8))
                path.addLine(to: CGPoint(x: 3.0, y: 9.2))
                path.move(to: CGPoint(x: 4.8, y: 3.0))
                path.addLine(to: CGPoint(x: 9.4, y: 3.0))
                path.addLine(to: CGPoint(x: 11.0, y: 4.6))
                path.addLine(to: CGPoint(x: 11.0, y: 9.2))
            case .merged:
                path.move(to: CGPoint(x: 4.6, y: 4.6))
                path.addLine(to: CGPoint(x: 7.1, y: 7.0))
                path.addLine(to: CGPoint(x: 9.2, y: 7.0))
                path.move(to: CGPoint(x: 4.6, y: 9.4))
                path.addLine(to: CGPoint(x: 7.1, y: 7.0))
            }
        }
        .stroke(.foreground, style: Self.stroke)
    }

    private var nodes: some View {
        // Third node sits at the bottom-right for an open PR, mid-right for a
        // merged one — mirroring the GitHub glyphs.
        let centers: [CGPoint] = kind == .open
            ? [CGPoint(x: 3, y: 3), CGPoint(x: 3, y: 11), CGPoint(x: 11, y: 11)]
            : [CGPoint(x: 3, y: 3), CGPoint(x: 3, y: 11), CGPoint(x: 11, y: 7)]
        return ZStack {
            ForEach(0..<centers.count, id: \.self) { index in
                Circle()
                    .stroke(.foreground, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(centers[index])
            }
        }
        .frame(width: Self.canvas, height: Self.canvas)
    }
}

extension SupermuxPullRequest.Status {
    /// State tint (GitHub-style): green open, purple merged, red closed. Bright
    /// enough to read on both light and dark sidebar backgrounds.
    var supermuxTint: Color {
        switch self {
        case .open: return Color(red: 0.247, green: 0.722, blue: 0.314)
        case .merged: return Color(red: 0.639, green: 0.443, blue: 0.969)
        case .closed: return Color(red: 0.973, green: 0.318, blue: 0.286)
        }
    }

    /// Localized lowercase state word (used in the accessibility label).
    var supermuxLabel: String {
        switch self {
        case .open:
            return String(localized: "supermux.pullRequest.status.open", defaultValue: "open")
        case .merged:
            return String(localized: "supermux.pullRequest.status.merged", defaultValue: "merged")
        case .closed:
            return String(localized: "supermux.pullRequest.status.closed", defaultValue: "closed")
        }
    }

    /// Localized tooltip for opening the PR.
    func supermuxOpenHelp(number: Int) -> String {
        String(localized: "supermux.pullRequest.open.help", defaultValue: "Open pull request #\(number)")
    }

    /// Localized accessibility label carrying the state word the compact badge
    /// omits visually (e.g. "Pull request #1234, merged").
    func supermuxAccessibilityLabel(number: Int) -> String {
        String(
            localized: "supermux.pullRequest.accessibility",
            defaultValue: "Pull request #\(number), \(supermuxLabel)"
        )
    }
}
