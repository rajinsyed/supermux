import SwiftUI

/// Draws the GitHub-style git-pull-request glyph (two branch nodes joined to
/// a third) with the same path geometry as the Mac's
/// `SupermuxPullRequestGlyph`, scaled from its native 13-unit canvas to
/// `size` — so the phone's PR badge and the sidebar's are pixel-twins.
/// Strokes with `.foreground`; the badge's state tint colors it.
struct SupermuxMobilePullRequestGlyph: View {
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
