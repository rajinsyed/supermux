import SwiftUI

/// Draws the GitHub-style git-pull-request glyph with the same path geometry
/// as the Mac's `SupermuxPullRequestGlyph`, scaled from its native 13-unit
/// canvas to `size` — so the phone's PR badge and the sidebar's are
/// pixel-twins. Strokes with `.foreground`; the badge's state tint colors it.
///
/// The open glyph carries a left-pointing **arrowhead**: two branches with a
/// bare connector is the `git-branch` icon, not `git-pull-request`, and the
/// arrow is the difference. Keep this geometry in step with the Mac's — the
/// two are deliberate copies so the platforms cannot drift visually.
struct SupermuxMobilePullRequestGlyph: View {
    /// Which PR glyph to draw.
    enum Kind { case open, merged }

    let kind: Kind
    let size: CGFloat

    private static let canvas: CGFloat = 13
    private static let nodeDiameter: CGFloat = 3
    private static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
    /// Where the open glyph's arrow tip lands (matches the Mac's).
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
                // LEFT into an arrowhead aimed at the left branch. Separate
                // strokes, as in GitHub's octicon, so the arrow reads as
                // flying between the two branches.
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
