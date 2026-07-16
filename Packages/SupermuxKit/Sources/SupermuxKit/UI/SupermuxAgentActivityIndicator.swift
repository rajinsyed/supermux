public import SwiftUI
import AppKit
import QuartzCore

/// A compact, animated indicator for a workspace's agent activity, shared by
/// the sidebar rows and tabs so every surface speaks the same visual language
/// (mirrors piggycode/superset):
///
/// - ``SupermuxWorkspaceActivity/working``: an amber braille spinner.
/// - ``SupermuxWorkspaceActivity/needsInput``: a red pulsing dot (a "ping" halo
///   behind a solid dot) — the most attention-grabbing state.
/// - ``SupermuxWorkspaceActivity/ready``: a steady green dot.
/// - ``SupermuxWorkspaceActivity/idle``: renders nothing.
public struct SupermuxAgentActivityIndicator: View {
    private let activity: SupermuxWorkspaceActivity
    private let size: CGFloat

    /// Creates an indicator.
    /// - Parameters:
    ///   - activity: The state to render.
    ///   - size: Diameter of the dot (the spinner scales from it). Defaults to 7.
    public init(activity: SupermuxWorkspaceActivity, size: CGFloat = 7) {
        self.activity = activity
        self.size = size
    }

    public var body: some View {
        Group {
            switch activity {
            case .working:
                SupermuxBrailleSpinner(size: size)
            case .needsInput:
                SupermuxPulsingDot(color: SupermuxActivityPalette.needsInput, size: size)
            case .ready:
                SupermuxStatusDot(color: SupermuxActivityPalette.ready, size: size)
            case .idle:
                EmptyView()
            }
        }
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    private var tooltip: String {
        switch activity {
        case .working:
            return String(localized: "supermux.activity.working", defaultValue: "Agent working")
        case .needsInput:
            return String(localized: "supermux.activity.needsInput", defaultValue: "Needs your input")
        case .ready:
            return String(localized: "supermux.activity.ready", defaultValue: "Ready for review")
        case .idle:
            return ""
        }
    }
}

/// Shared activity colors, tuned to read well on the sidebar's dark chrome and
/// matched to superset's amber/red/green status palette.
enum SupermuxActivityPalette {
    /// amber-500 — agent working.
    static let working = Color(red: 0.96, green: 0.62, blue: 0.04)
    /// red-500 — needs input.
    static let needsInput = Color(red: 0.94, green: 0.27, blue: 0.27)
    /// green-500 — ready for review.
    static let ready = Color(red: 0.13, green: 0.77, blue: 0.37)
}

/// An amber braille spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) ported from piggycode's
/// `AsciiSpinner`.
///
/// CPU-safety (this is a terminal app where main-thread time is precious):
/// the animation is a Core Animation `contents` keyframe loop on a plain
/// `CALayer` (render-server driven, like cmux's `GPUSpinnerNSView`), so a
/// spinning indicator does no per-frame SwiftUI or main-thread work. An earlier
/// `TimelineView(.animation)` implementation kept the window's display link
/// alive at full refresh rate and forced a window-wide SwiftUI layout pass on
/// every glyph tick, which alone burned ~15% CPU while any agent was working
/// (found via `sample`/Instruments on the Release app). Animations stop while
/// the window is occluded or Reduce Motion is on.
struct SupermuxBrailleSpinner: View {
    let size: CGFloat

    var body: some View {
        SupermuxBrailleSpinnerRepresentable(size: size)
            // Reserve the dot's footprint so rows don't shift between states
            // (the glyph intentionally overdraws the frame, like the original
            // Text-based spinner did).
            .frame(width: size, height: size)
            .fixedSize()
    }
}

private struct SupermuxBrailleSpinnerRepresentable: NSViewRepresentable {
    let size: CGFloat

    func makeNSView(context: Context) -> SupermuxBrailleSpinnerNSView {
        let view = SupermuxBrailleSpinnerNSView(frame: .zero)
        view.glyphPointSize = size * 1.7
        return view
    }

    func updateNSView(_ view: SupermuxBrailleSpinnerNSView, context: Context) {
        view.glyphPointSize = size * 1.7
    }
}

/// A solid dot with a looping "ping" halo behind it (Tailwind `animate-ping`),
/// for the attention-grabbing needs-input state.
///
/// The halo is a Core Animation scale+fade loop on its own `CALayer`
/// (render-server driven, no per-frame SwiftUI or main-thread work). An earlier
/// implementation used SwiftUI `withAnimation(.repeatForever)`, which drives
/// the whole hosting view's update cycle from the main thread at display
/// refresh rate. Animations stop while the window is occluded or Reduce
/// Motion is on; the solid dot always shows.
struct SupermuxPulsingDot: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        SupermuxPulsingDotRepresentable(color: color, size: size)
            .frame(width: size, height: size)
    }
}

private struct SupermuxPulsingDotRepresentable: NSViewRepresentable {
    let color: Color
    let size: CGFloat

    func makeNSView(context: Context) -> SupermuxPulsingDotNSView {
        let view = SupermuxPulsingDotNSView(frame: .zero)
        view.dotColor = NSColor(color)
        return view
    }

    func updateNSView(_ view: SupermuxPulsingDotNSView, context: Context) {
        view.dotColor = NSColor(color)
    }
}

/// A steady, filled status dot.
struct SupermuxStatusDot: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

// MARK: - Core Animation backing views

/// Base class for the render-server-driven activity indicators: owns the
/// visible/occluded/Reduce-Motion bookkeeping (mirroring cmux's
/// `GPUSpinnerNSView`) so subclasses only describe their layers and looping
/// animations.
class SupermuxActivityAnimationNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(visibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibilityChanged),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
        }
        updateAnimationState()
    }

    override func layout() {
        super.layout()
        layoutAnimationContent()
        updateAnimationState()
    }

    @objc private func visibilityChanged() {
        updateAnimationState()
    }

    private var shouldAnimate: Bool {
        guard let window else { return false }
        guard window.occlusionState.contains(.visible) else { return false }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return false }
        return min(bounds.width, bounds.height) > 0
    }

    func updateAnimationState() {
        if shouldAnimate {
            installAnimationIfNeeded()
        } else {
            removeAnimation()
        }
    }

    /// Anchors `beginTime` to the shared Core Animation media clock so all
    /// indicators of the same duration stay phase-locked, even when their
    /// layer hierarchies have different local time bases.
    func syncedBeginTime(for layer: CALayer, duration: CFTimeInterval) -> CFTimeInterval {
        let globalNow = CACurrentMediaTime()
        let layerNow = layer.convertTime(globalNow, from: nil)
        let sharedPhase = globalNow.truncatingRemainder(dividingBy: duration)
        return layerNow - sharedPhase
    }

    /// Subclass hooks.
    func layoutAnimationContent() {}
    func installAnimationIfNeeded() {}
    func removeAnimation() {}
}

/// Braille-glyph spinner: a `CALayer` whose `contents` steps through the ten
/// pre-rendered glyph bitmaps at 12.5 fps, entirely on the render server.
final class SupermuxBrailleSpinnerNSView: SupermuxActivityAnimationNSView {
    private static let animationKey = "supermux.brailleSpinner.contents"
    private static let frames: [String] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private static let frameInterval: TimeInterval = 0.08

    private let glyphLayer = CALayer()
    private var frameImages: [CGImage] = []
    private var renderedForPointSize: CGFloat = 0
    private var renderedForScale: CGFloat = 0
    private var glyphCellSize: CGSize = .zero

    var glyphPointSize: CGFloat = 12 {
        didSet {
            guard abs(glyphPointSize - oldValue) > 0.01 else { return }
            renderFramesIfNeeded()
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyphLayer.contentsGravity = .center
        glyphLayer.masksToBounds = false
        layer?.addSublayer(glyphLayer)
        renderFramesIfNeeded()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderFramesIfNeeded()
        updateAnimationState()
    }

    override func layoutAnimationContent() {
        glyphLayer.bounds = CGRect(origin: .zero, size: glyphCellSize)
        glyphLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func installAnimationIfNeeded() {
        renderFramesIfNeeded()
        guard glyphLayer.animation(forKey: Self.animationKey) == nil, !frameImages.isEmpty else { return }
        let duration = Self.frameInterval * Double(Self.frames.count)
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frameImages
        // Discrete keyframes need values.count + 1 key times, terminating at
        // 1.0 — each pair [t(i), t(i+1)) is one frame's display window. With
        // only values.count entries CA considers the timing malformed and
        // freezes on the first frame.
        animation.keyTimes = (0...Self.frames.count).map { NSNumber(value: Double($0) / Double(Self.frames.count)) }
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.beginTime = syncedBeginTime(for: glyphLayer, duration: duration)
        glyphLayer.add(animation, forKey: Self.animationKey)
    }

    override func removeAnimation() {
        glyphLayer.removeAnimation(forKey: Self.animationKey)
        // Reduce Motion / occlusion fallback: hold the first glyph.
        glyphLayer.contents = frameImages.first
    }

    /// Test seams — behavior coverage lives in
    /// `SupermuxAgentActivityIndicatorTests`.
    var renderedFrameCountForTesting: Int { frameImages.count }
    var isAnimationInstalledForTesting: Bool { glyphLayer.animation(forKey: Self.animationKey) != nil }
    var glyphCellSizeForTesting: CGSize { glyphCellSize }
    var installedAnimationFramesForTesting: [CGImage]? {
        (glyphLayer.animation(forKey: Self.animationKey) as? CAKeyframeAnimation)?.values as? [CGImage]
    }

    private func renderFramesIfNeeded() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard renderedForPointSize != glyphPointSize || renderedForScale != scale else { return }
        renderedForPointSize = glyphPointSize
        renderedForScale = scale

        let font = NSFont.monospacedSystemFont(ofSize: glyphPointSize, weight: .semibold)
        let color = NSColor(SupermuxActivityPalette.working)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        // Monospaced font: every glyph shares the same cell, so the layer's
        // size stays constant across frames and nothing ever re-layouts.
        let cell = Self.frames.reduce(CGSize.zero) { acc, glyph in
            let size = NSAttributedString(string: glyph, attributes: attributes).size()
            return CGSize(width: max(acc.width, ceil(size.width)), height: max(acc.height, ceil(size.height)))
        }
        glyphCellSize = cell
        glyphLayer.contentsScale = scale
        frameImages = Self.frames.compactMap { glyph in
            Self.renderGlyph(glyph, attributes: attributes, cell: cell, scale: scale)
        }
        glyphLayer.contents = frameImages.first
        needsLayout = true
        // An installed animation owns the image array it was created with, so
        // a size/scale re-render must swap it for one built from the new
        // frames — otherwise the spinner keeps animating the stale bitmaps.
        if glyphLayer.animation(forKey: Self.animationKey) != nil {
            glyphLayer.removeAnimation(forKey: Self.animationKey)
            updateAnimationState()
        }
    }

    private static func renderGlyph(
        _ glyph: String,
        attributes: [NSAttributedString.Key: Any],
        cell: CGSize,
        scale: CGFloat
    ) -> CGImage? {
        let pixelWide = max(1, Int(ceil(cell.width * scale)))
        let pixelHigh = max(1, Int(ceil(cell.height * scale)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWide,
            pixelsHigh: pixelHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = cell
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        let attributed = NSAttributedString(string: glyph, attributes: attributes)
        let glyphSize = attributed.size()
        attributed.draw(at: NSPoint(
            x: (cell.width - glyphSize.width) / 2,
            y: (cell.height - glyphSize.height) / 2
        ))
        context.flushGraphics()
        return rep.cgImage
    }
}

/// Needs-input dot: a solid dot layer plus a halo layer running a
/// scale-up-and-fade loop (Tailwind `animate-ping`), entirely on the render
/// server.
final class SupermuxPulsingDotNSView: SupermuxActivityAnimationNSView {
    private static let animationKey = "supermux.pulsingDot.ping"
    private static let pingDuration: CFTimeInterval = 1.1
    private static let pingScale: CGFloat = 2.3
    private static let pingStartOpacity: Float = 0.7

    private let dotLayer = CALayer()
    private let haloLayer = CALayer()

    var dotColor: NSColor = .systemRed {
        didSet { applyColor() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        haloLayer.opacity = 0
        layer?.addSublayer(haloLayer)
        layer?.addSublayer(dotLayer)
        applyColor()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutAnimationContent() {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let dotBounds = CGRect(x: 0, y: 0, width: side, height: side)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for target in [dotLayer, haloLayer] {
            target.bounds = dotBounds
            target.position = center
            target.cornerRadius = side / 2
        }
    }

    override func installAnimationIfNeeded() {
        guard haloLayer.animation(forKey: Self.animationKey) == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = Self.pingScale
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = Self.pingStartOpacity
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = Self.pingDuration
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.beginTime = syncedBeginTime(for: haloLayer, duration: Self.pingDuration)
        haloLayer.add(group, forKey: Self.animationKey)
    }

    override func removeAnimation() {
        haloLayer.removeAnimation(forKey: Self.animationKey)
        haloLayer.opacity = 0
    }

    /// Test seams — behavior coverage lives in
    /// `SupermuxAgentActivityIndicatorTests`.
    var isPingAnimationInstalledForTesting: Bool { haloLayer.animation(forKey: Self.animationKey) != nil }
    var dotColorForTesting: CGColor? { dotLayer.backgroundColor }

    private func applyColor() {
        let cg = dotColor.usingColorSpace(.deviceRGB)?.cgColor ?? dotColor.cgColor
        dotLayer.backgroundColor = cg
        haloLayer.backgroundColor = cg
    }
}
