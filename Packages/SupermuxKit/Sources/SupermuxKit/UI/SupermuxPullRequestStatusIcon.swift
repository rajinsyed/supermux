import SwiftUI

/// The status icon the Changes panel's PR header buttons draw: a real
/// git-pull-request glyph for open/merged (matching cmux's own PR icons) and a
/// bare `xmark` for closed. Inherits the surrounding `foregroundStyle`, so the
/// caller's state tint colors it. Every case is drawn into the same `size`
/// footprint so all three center identically.
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
/// Strokes with `.foreground`, so the caller's `foregroundStyle` tint colors it.
///
/// The open glyph carries a left-pointing **arrowhead**: two branches with a
/// bare connector is the `git-branch` icon, not `git-pull-request`, and the
/// arrow is the difference.
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
    /// enough to read on both light and dark backgrounds.
    var supermuxTint: Color {
        switch self {
        case .open: return Color(red: 0.247, green: 0.722, blue: 0.314)
        case .merged: return Color(red: 0.639, green: 0.443, blue: 0.969)
        case .closed: return Color(red: 0.973, green: 0.318, blue: 0.286)
        }
    }
}
