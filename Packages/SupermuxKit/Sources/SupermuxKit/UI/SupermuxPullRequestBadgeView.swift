public import SwiftUI

/// The clickable pull-request badge shown on sidebar worktree and nested
/// workspace rows: a round tinted chip carrying a real git-pull-request glyph,
/// colored by the PR's lifecycle state (green open, purple merged, red closed).
///
/// **Icon only — no `#1234`.** The badge sits at the right edge of rows that
/// already truncate the workspace title and its branch, so the number spent the
/// row's scarcest resource on the one thing in the badge nothing acts on: the
/// state is what the row reports, and the glyph's shape and tint carry it
/// already. Dropping the digits gives that width back to the two labels that
/// identify the row.
///
/// The number is not lost, only moved to where it costs no width: the hover
/// tooltip (`help`) and the accessibility label. On the desktop the tooltip is
/// the better home for it anyway — it can spell out "Open pull request #1234"
/// in full, which the badge never had room to do.
///
/// State conveyed by shape and color, the word reserved for VoiceOver. Used by
/// both ``SupermuxOpenWorkspaceRowView`` and ``SupermuxWorktreeRowView`` so the
/// badge looks identical wherever a worktree appears, and mirrored on the phone
/// by `SupermuxMobilePullRequestBadge`. Holds only a value and an open closure,
/// so it crosses the sidebar snapshot boundary cleanly.
public struct SupermuxPullRequestBadge: View {
    private let pullRequest: SupermuxPullRequest
    private let fontScale: CGFloat
    private let onOpen: (URL) -> Void

    /// The glyph's footprint at `fontScale == 1`. Up from the 11 it drew beside
    /// the number: with nothing next to it the glyph is the whole badge, so it
    /// carries the state alone.
    private static let baseGlyphSize: CGFloat = 12
    /// The chip's diameter at `fontScale == 1` — the glyph plus the breathing
    /// room the capsule gave it, now equal on all four sides.
    private static let baseChipSize: CGFloat = 18

    /// Creates a badge.
    /// - Parameters:
    ///   - pullRequest: The pull request to display.
    ///   - fontScale: Sidebar font scale (cmux's `sidebar-font-size`); `1` at the
    ///     default size, multiplied into the badge's icon and chip.
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
            SupermuxPullRequestStatusIcon(
                status: pullRequest.status,
                size: Self.baseGlyphSize * fontScale
            )
            .foregroundStyle(pullRequest.status.supermuxTint)
            .opacity(pullRequest.isStale ? 0.5 : 1)
            .frame(
                width: Self.baseChipSize * fontScale,
                height: Self.baseChipSize * fontScale
            )
            .background(Circle().fill(pullRequest.status.supermuxTint.opacity(0.16)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(pullRequest.status.supermuxOpenHelp(number: pullRequest.number))
        .accessibilityLabel(pullRequest.status.supermuxAccessibilityLabel(number: pullRequest.number))
        .accessibilityAddTraits(.isButton)
    }
}

/// The status icon: a real git-pull-request glyph for open/merged (matching
/// cmux's own sidebar PR icons) and a bare `xmark` for closed. Inherits the
/// surrounding `foregroundStyle`, so the badge's state tint colors it.
///
/// Closed draws `xmark`, not `xmark.circle`: the badge's own chip is the circle
/// now, and the ringed variant put a circle inside a circle. Every case is
/// drawn into the same `size` footprint so all three center identically in the
/// chip.
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
            Image(systemName: "xmark")
                .font(.system(size: size * 0.78, weight: .semibold))
                .frame(width: size, height: size)
        }
    }
}

/// Draws the GitHub-style git-pull-request glyph using the same path geometry
/// as cmux's sidebar PR icons, scaled from its native 13-unit canvas to `size`.
/// Strokes with `.foreground`, so the badge's `foregroundStyle` tint colors it.
///
/// The open glyph carries a left-pointing **arrowhead**: two branches with a
/// bare connector is the `git-branch` icon, not `git-pull-request`, and the
/// arrow is the difference. It went unnoticed while `#1234` sat beside the
/// glyph and carried the meaning; making the badge icon-only put the whole job
/// on the glyph and exposed it.
struct SupermuxPullRequestGlyph: View {
    /// Which PR glyph to draw.
    enum Kind { case open, merged }

    let kind: Kind
    let size: CGFloat

    private static let canvas: CGFloat = 13
    private static let nodeDiameter: CGFloat = 3
    private static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
    /// Where the open glyph's arrow tip lands. Far enough left to read as
    /// aimed at the left branch, not so far it collides with that branch's
    /// node at 12pt.
    private static let arrowTipX: CGFloat = 6.6
    /// How far each barb trails behind the tip, on both axes (45° barbs).
    private static let arrowBarb: CGFloat = 1.4

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
                // Left branch: a bare shaft between its two nodes.
                path.move(to: CGPoint(x: 3.0, y: 4.8))
                path.addLine(to: CGPoint(x: 3.0, y: 9.2))
                // Right branch: up from its node, round the corner, then run
                // LEFT and end in an arrowhead aimed at the left branch. The
                // arrow is the whole point of the glyph — it is what says
                // "merge this into that" rather than "here are two branches" —
                // and the two branches stay separate strokes, as in GitHub's
                // own octicon, so the arrow reads as flying between them.
                path.move(to: CGPoint(x: 11.0, y: 9.2))
                path.addLine(to: CGPoint(x: 11.0, y: 4.6))
                path.addArc(
                    tangent1End: CGPoint(x: 11.0, y: 3.0),
                    tangent2End: CGPoint(x: Self.arrowTipX, y: 3.0),
                    radius: 1.6
                )
                path.addLine(to: CGPoint(x: Self.arrowTipX, y: 3.0))
                path.move(to: CGPoint(x: Self.arrowTipX + Self.arrowBarb, y: 3.0 - Self.arrowBarb))
                path.addLine(to: CGPoint(x: Self.arrowTipX, y: 3.0))
                path.addLine(to: CGPoint(x: Self.arrowTipX + Self.arrowBarb, y: 3.0 + Self.arrowBarb))
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
