import AVFoundation
import AppKit
import CmuxMobileSimulatorStream
import CmuxSimulatorStreamKit
import CoreMedia

/// The video and input surface of a remote-simulator viewer.
///
/// Frames go straight to an `AVSampleBufferDisplayLayer`, which decodes the
/// owning Mac's HEVC/H.264 in hardware and shows each one at once (a port of
/// the iPhone's `SimStreamDisplayView`). Clicks and drags become one-finger
/// touches, a trackpad scroll becomes a one-finger drag, keys become HID key
/// events and ⌘V types this Mac's clipboard; the simulator's own UIKit does
/// every gesture's physics. Points are measured from the top-left corner of
/// the aspect-fit video, as the stream's touch coordinates are.
@MainActor
final class SupermuxRemoteSimulatorDisplayView: NSView {
    /// One input event for the stream (the panel forwards it).
    var onInput: ((SimStreamInputEvent) -> Void)?
    /// A click asks the workspace to focus this panel.
    var onFocusRequest: (() -> Void)?
    /// The view's long side in backing pixels, for Auto quality.
    var onBackingLongSideChange: ((CGFloat) -> Void)?

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var configPixelSize = CGSize.zero
    private var pointerIsDown = false
    /// Where a trackpad scroll's synthesized finger is, in top-left view points.
    private var scrollFinger: CGPoint?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SupermuxRemoteSimulatorDisplayView is code-only")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
        reportBackingLongSide()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportBackingLongSide()
    }

    private func reportBackingLongSide() {
        let longSide = max(bounds.width, bounds.height) * (window?.backingScaleFactor ?? 2)
        if longSide > 0 { onBackingLongSideChange?(longSide) }
    }

    // MARK: - Rendering

    func applyConfig(_ config: SimStreamConfig) {
        configPixelSize = CGSize(width: CGFloat(config.pixelWidth), height: CGFloat(config.pixelHeight))
        displayLayer.sampleBufferRenderer.flush()
    }

    /// Whether the frame went to a healthy renderer (only then is it acked).
    func enqueue(_ sampleBuffer: CMSampleBuffer, isKeyframe: Bool) -> Bool {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
            return false
        }
        if renderer.requiresFlushToResumeDecoding {
            guard isKeyframe else { return false }
            renderer.flush()
        }
        guard renderer.isReadyForMoreMediaData else { return false }
        renderer.enqueue(sampleBuffer)
        return renderer.status != .failed
    }

    func resetRenderer() {
        displayLayer.sampleBufferRenderer.flush()
    }

    /// The renderer's status, for the DEBUG drivers.
    var rendererStatusName: String {
        switch displayLayer.sampleBufferRenderer.status {
        case .rendering: "rendering"
        case .failed: "failed"
        default: "unknown"
        }
    }

    // MARK: - Pointer

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocusRequest?()
        guard scrollFinger == nil, let point = normalized(topLeftPoint(event), clamped: false) else { return }
        pointerIsDown = true
        emitTouch(.began, point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pointerIsDown, let point = normalized(topLeftPoint(event), clamped: true) else { return }
        emitTouch(.moved, point)
    }

    override func mouseUp(with event: NSEvent) {
        guard pointerIsDown else { return }
        pointerIsDown = false
        emitTouch(.ended, normalized(topLeftPoint(event), clamped: true) ?? .zero)
    }

    /// A phased trackpad scroll drags one finger from the pointer by the
    /// scroll's deltas (with natural scrolling the content follows the
    /// fingers, as on the phone). Momentum is the simulator's own; mouse-wheel
    /// notches are not sent.
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, !pointerIsDown else { return }
        switch event.phase {
        case .began:
            let start = topLeftPoint(event)
            guard let point = normalized(start, clamped: false) else { return }
            scrollFinger = start
            emitTouch(.began, point)
        case .changed:
            guard var finger = scrollFinger else { return }
            finger.x += event.scrollingDeltaX
            finger.y += event.scrollingDeltaY
            scrollFinger = finger
            if let point = normalized(finger, clamped: true) { emitTouch(.moved, point) }
        case .ended, .cancelled:
            guard let finger = scrollFinger else { return }
            scrollFinger = nil
            emitTouch(.ended, normalized(finger, clamped: true) ?? .zero)
        default:
            break
        }
    }

    private func topLeftPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
    }

    private func normalized(_ point: CGPoint, clamped: Bool) -> CGPoint? {
        let mapping = SimStreamTouchMapping()
        return clamped
            ? mapping.clampedNormalizedPoint(point, pixelSize: configPixelSize, in: bounds)
            : mapping.normalizedPoint(point, pixelSize: configPixelSize, in: bounds)
    }

    private func emitTouch(_ phase: SimStreamTouchPhase, _ point: CGPoint) {
        onInput?(.touch(
            phase: phase,
            pointerID: 0,
            x: Float(point.x),
            y: Float(point.y),
            timestampMicroseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
        ))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // The simulator repeats a held key itself; ⌘-chords this Mac's menus
        // did not take never reach the simulator as a plain key.
        guard !event.isARepeat, !event.modifierFlags.contains(.command) else { return }
        guard let usage = SupermuxRemoteSimulatorKeyMap.usage(for: event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        onInput?(.key(usage: usage, isDown: true))
    }

    override func keyUp(with event: NSEvent) {
        guard let usage = SupermuxRemoteSimulatorKeyMap.usage(for: event.keyCode) else {
            super.keyUp(with: event)
            return
        }
        onInput?(.key(usage: usage, isDown: false))
    }

    override func flagsChanged(with event: NSEvent) {
        guard !SupermuxRemoteSimulatorKeyMap.commandKeyCodes.contains(event.keyCode),
              let usage = SupermuxRemoteSimulatorKeyMap.usage(for: event.keyCode),
              let isDown = SupermuxRemoteSimulatorKeyMap.modifierIsDown(for: event.keyCode, flags: event.modifierFlags) else {
            super.flagsChanged(with: event)
            return
        }
        onInput?(.key(usage: usage, isDown: isDown))
    }

    /// Edit > Paste (⌘V): types this Mac's clipboard text on the simulator.
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        onInput?(.text(text))
    }
}

/// Bridges the stream engine (any executor) to the main-actor display view
/// and its panel (a port of the iPhone's `SimStreamViewPresenter`).
///
/// Checked by hand: the stored properties are a weak reference (weak loads
/// are thread-safe) and a main-actor closure, and both are only used inside
/// `MainActor.run`.
final class SupermuxRemoteSimulatorPresenter: SimStreamFramePresenting, @unchecked Sendable {
    /// CoreMedia sample buffers are immutable after creation, and the engine
    /// never touches one after handing it over.
    private struct SampleBufferBox: @unchecked Sendable {
        let buffer: CMSampleBuffer
    }

    private weak var view: SupermuxRemoteSimulatorDisplayView?
    private let onConfig: @MainActor @Sendable (SimStreamConfig) -> Void

    init(view: SupermuxRemoteSimulatorDisplayView, onConfig: @escaping @MainActor @Sendable (SimStreamConfig) -> Void) {
        self.view = view
        self.onConfig = onConfig
    }

    func applyConfig(_ config: SimStreamConfig) async {
        let onConfig = onConfig
        await MainActor.run { [weak view] in
            view?.applyConfig(config)
            onConfig(config)
        }
    }

    func present(_ sampleBuffer: sending CMSampleBuffer, sequence: UInt64, isKeyframe: Bool) async -> Bool {
        let box = SampleBufferBox(buffer: sampleBuffer)
        return await MainActor.run { [weak view] in
            view?.enqueue(box.buffer, isKeyframe: isKeyframe) ?? false
        }
    }

    func reset() async {
        await MainActor.run { [weak view] in
            view?.resetRenderer()
        }
    }
}
