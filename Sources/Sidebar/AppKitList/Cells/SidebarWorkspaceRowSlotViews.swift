import AppKit
import CmuxFoundation
import CmuxSidebar
// SUPERMUX:begin supermux-unread-badge-capsule (shared badge geometry + paint)
import SupermuxKit
import SupermuxMobileCore
// SUPERMUX:end supermux-unread-badge-capsule

/// Leaf AppKit views for the pure-AppKit workspace row: unread badge,
/// pull-request status icons, progress bar. Each is configured with values
/// only and draws without Auto Layout.

extension NSTextField {
    /// Unconstrained text measurement for manual layout. Never use
    /// `intrinsicContentSize` to size these labels: on a truncating
    /// single-line field it caps at the CURRENT frame width, so a pooled
    /// view laid out narrow once (they start at zero width) reports — and
    /// keeps — the truncated width no matter how much space the row has.
    /// That is exactly the "PR #4  o…" bug.
    var sidebarNaturalCellSize: NSSize {
        cell?.cellSize(forBounds: NSRect(
            x: 0, y: 0,
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )) ?? .zero
    }
}

/// SUPERMUX: capsule unread-count badge, matched to the SwiftUI
/// ``SupermuxUnreadBadgeView`` (and so to the phone's badge) through the shared
/// ``SupermuxUnreadBadgeStyle``.
///
/// Draws the count directly so the glyph is optically centered — NSTextField
/// intrinsic sizing carries asymmetric insets that shift small digits.
///
/// The gradient and rim are painted here rather than composed from layers
/// because this whole cell is hand-laid-out Core Graphics for scroll
/// performance; adding sublayers per row to a pooled cell is exactly the cost
/// this list exists to avoid. The VALUES all come from the shared style, so
/// "matched to SwiftUI" is a shared table, not a hand-tuned copy.
///
/// The shadow is the one exception: it falls OUTSIDE the badge's bounds, and
/// this view is sized to the badge exactly, so drawing it here would clip it.
/// It is applied to the layer instead — one shadow on one small layer, which
/// the cell already has.
extension SupermuxUnreadBadgeStyle {
    /// Measures the badge with an AppKit font, so the two hand-laid-out sidebar
    /// cells cannot drift apart in how they size it.
    ///
    /// The core `size(count:textWidth:)` takes a pre-measured width because the
    /// package it lives in deliberately imports no UI framework; this is the
    /// AppKit half of that split, and it is the only measurement path either
    /// cell should use.
    /// - Parameters:
    ///   - count: The unread count, or `nil` for the countless dot form.
    ///   - font: The font the numeral will actually be drawn in.
    /// - Returns: The badge's size.
    @MainActor
    static func size(count: Int?, font: NSFont) -> NSSize {
        let style = SupermuxUnreadBadgeStyle(fontSize: font.pointSize)
        let text = SupermuxUnreadBadgeStyle.displayText(count: count) ?? ""
        let textWidth = NSString(string: text).size(withAttributes: [.font: font]).width
        return style.size(count: count, textWidth: textWidth)
    }
}

@MainActor
final class SidebarRowUnreadBadgeView: NSView {
    private var text: NSString = ""
    private var textAttributes: [NSAttributedString.Key: Any] = [:]
    private var fillColor: NSColor = .controlAccentColor
    private var style = SupermuxUnreadBadgeStyle(fontSize: 9)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Painted in `draw`, not by the layer: a layer background would square
        // off behind the capsule's rounded ends.
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(count: Int, fillColor: NSColor, textColor: NSColor, font: NSFont) {
        text = NSString(string: SupermuxUnreadBadgeStyle.displayText(count: count) ?? "")
        textAttributes = [.font: font, .foregroundColor: textColor]
        self.fillColor = fillColor
        style = SupermuxUnreadBadgeStyle(fontSize: font.pointSize)
        // The accent-tinted lift, matching the SwiftUI badge's `.shadow`. On the
        // layer rather than in `draw` because it extends past the view's own
        // bounds, which are the badge's exact size.
        layer?.masksToBounds = false
        layer?.shadowColor = fillColor.cgColor
        layer?.shadowOpacity = Float(SupermuxUnreadBadgeStyle.shadowOpacity)
        layer?.shadowRadius = style.shadowRadius
        // AppKit's y axis points up, so a shadow BELOW the badge is negative
        // here where SwiftUI's `y:` is positive.
        layer?.shadowOffset = CGSize(width: 0, height: -style.shadowOffsetY)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let radius = min(bounds.height, bounds.width) / 2
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let radius = min(bounds.height, bounds.width) / 2
        let capsule = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)

        context.saveGState()
        capsule.addClip()
        fillColor.setFill()
        bounds.fill()
        // Light-from-above wash over the caller's fill, so the badge reads as a
        // lit object rather than a flat sticker.
        if let gradient = NSGradient(
            colors: SupermuxUnreadBadgeGradient.appKitStops.map(\.color),
            atLocations: SupermuxUnreadBadgeGradient.appKitStops.map(\.location),
            colorSpace: .sRGB
        ) {
            gradient.draw(in: bounds, angle: -90)
        }
        context.restoreGState()

        // Hairline rim just INSIDE the edge: stroking the path itself would
        // straddle it and clip the outer half.
        let rimWidth = style.rimWidth
        let rimRect = bounds.insetBy(dx: rimWidth / 2, dy: rimWidth / 2)
        let rimRadius = max(0, radius - rimWidth / 2)
        let rim = NSBezierPath(roundedRect: rimRect, xRadius: rimRadius, yRadius: rimRadius)
        rim.lineWidth = rimWidth
        NSColor.white.withAlphaComponent(SupermuxUnreadBadgeStyle.rimOpacity).setStroke()
        rim.stroke()

        guard text.length > 0, let font = textAttributes[.font] as? NSFont else { return }
        let size = text.size(withAttributes: textAttributes)
        // Center on the digit's cap-height band, not the full line box, so
        // single digits sit optically centered.
        let capCenterOffset = (font.ascender + font.descender) / 2
        let y = bounds.midY - size.height / 2 + (size.height / 2 - font.ascender + capCenterOffset)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: y),
            withAttributes: textAttributes
        )
    }
}

/// Pull-request status icon (custom vector open/merged glyphs, SF closed).
/// Ports PullRequestOpenIcon / PullRequestMergedIcon exactly: 13x13 design
/// space, 1.2 stroke, 3.0 node circles, scaled by fontScale.
@MainActor
final class SidebarRowPullRequestIconView: NSView {
    private var status: SidebarPullRequestStatus = .open
    private var color: NSColor = .secondaryLabelColor
    private var fontScale: CGFloat = 1

    override var isFlipped: Bool { true }

    func configure(status: SidebarPullRequestStatus, color: NSColor, fontScale: CGFloat) {
        self.status = status
        self.color = color
        self.fontScale = fontScale
        needsDisplay = true
    }

    static func size(status: SidebarPullRequestStatus, fontScale: CGFloat) -> NSSize {
        switch status {
        case .closed:
            return NSSize(width: 12 * fontScale, height: 12 * fontScale)
        default:
            return NSSize(width: 13 * fontScale, height: 13 * fontScale)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        color.setStroke()

        if status == .closed {
            let image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "xmark.circle",
                pointSize: 7 * fontScale,
                weight: nil
            )
            if let image {
                let rect = NSRect(
                    x: (bounds.width - image.size.width) / 2,
                    y: (bounds.height - image.size.height) / 2,
                    width: image.size.width,
                    height: image.size.height
                )
                // Tint inside the image first: .sourceAtop against the view's
                // transparent backing draws nothing (no destination pixels).
                let tinted = NSImage(size: image.size, flipped: false) { [color] drawRect in
                    image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
                    color.set()
                    drawRect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return
        }

        context.saveGState()
        context.scaleBy(x: fontScale, y: fontScale)
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        func node(_ x: CGFloat, _ y: CGFloat) {
            let d: CGFloat = 3.0
            let nodePath = NSBezierPath(ovalIn: NSRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
            nodePath.lineWidth = 1.2
            nodePath.stroke()
        }

        switch status {
        case .merged:
            path.move(to: NSPoint(x: 4.6, y: 4.6))
            path.line(to: NSPoint(x: 7.1, y: 7.0))
            path.line(to: NSPoint(x: 9.2, y: 7.0))
            path.move(to: NSPoint(x: 4.6, y: 9.4))
            path.line(to: NSPoint(x: 7.1, y: 7.0))
            path.stroke()
            node(3.0, 3.0)
            node(3.0, 11.0)
            node(11.0, 7.0)
        default:
            // SUPERMUX:begin pull-request-glyph-arrowhead (open-PR glyph gains its arrowhead — see SUPERMUX-TOUCHPOINTS.md)
            // The AppKit twin of the SwiftUI `PullRequestOpenIcon` fix: a bare
            // connector between two branches is `git-branch`, not
            // `git-pull-request`. Same 13-unit geometry, drawn with
            // NSBezierPath; this view is `isFlipped`, so y-down matches.
            path.move(to: NSPoint(x: 3.0, y: 4.8))
            path.line(to: NSPoint(x: 3.0, y: 9.2))
            path.move(to: NSPoint(x: 11.0, y: 9.2))
            path.line(to: NSPoint(x: 11.0, y: 4.6))
            path.appendArc(
                from: NSPoint(x: 11.0, y: 3.0),
                to: NSPoint(x: 6.6, y: 3.0),
                radius: 1.6
            )
            path.line(to: NSPoint(x: 6.6, y: 3.0))
            path.move(to: NSPoint(x: 8.0, y: 1.6))
            path.line(to: NSPoint(x: 6.6, y: 3.0))
            path.line(to: NSPoint(x: 8.0, y: 4.4))
            path.stroke()
            // SUPERMUX:end pull-request-glyph-arrowhead
            node(3.0, 3.0)
            node(3.0, 11.0)
            node(11.0, 11.0)
        }
        context.restoreGState()
    }
}

/// Capsule progress bar (track + leading-anchored fill + optional label).
@MainActor
final class SidebarRowProgressView: NSView {
    private let trackView = NSView()
    private let fillView = NSView()
    let label = NSTextField(labelWithString: "")
    private var fraction: CGFloat = 0
    private var barHeight: CGFloat = 3

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        trackView.wantsLayer = true
        fillView.wantsLayer = true
        addSubview(trackView)
        addSubview(fillView)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        fraction: CGFloat,
        barHeight: CGFloat,
        trackColor: NSColor,
        fillColor: NSColor,
        labelText: String?,
        labelFont: NSFont,
        labelColor: NSColor
    ) {
        self.fraction = max(0, min(1, fraction))
        self.barHeight = barHeight
        trackView.layer?.backgroundColor = trackColor.cgColor
        fillView.layer?.backgroundColor = fillColor.cgColor
        label.isHidden = labelText == nil
        label.stringValue = labelText ?? ""
        label.font = labelFont
        label.textColor = labelColor
        needsLayout = true
    }

    static func height(barHeight: CGFloat, labelText: String?, labelFont: NSFont) -> CGFloat {
        guard labelText != nil else { return barHeight }
        return barHeight + 2 + ceil(labelFont.ascender - labelFont.descender + labelFont.leading)
    }

    override func layout() {
        super.layout()
        trackView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        trackView.layer?.cornerRadius = barHeight / 2
        fillView.frame = NSRect(x: 0, y: 0, width: bounds.width * fraction, height: barHeight)
        fillView.layer?.cornerRadius = barHeight / 2
        if !label.isHidden {
            let size = label.sidebarNaturalCellSize
            label.frame = NSRect(x: 0, y: barHeight + 2, width: min(ceil(size.width), bounds.width), height: size.height)
        }
    }
}

extension NSAttributedString.Key {
    /// Row-owned replacement for `.link`. AppKit gives no way to override the
    /// color it paints `.link` runs in, so the sidebar carries the destination
    /// here and styles the run itself.
    static let sidebarRowLink = NSAttributedString.Key("com.cmux.sidebarRowLink")
}
