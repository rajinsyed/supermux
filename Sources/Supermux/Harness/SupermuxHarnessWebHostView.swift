import AppKit
import WebKit

struct SupermuxHarnessWebHostGeometryState: Equatable {
    let frame: CGRect
    let bounds: CGRect
    let windowNumber: Int?
    let superviewID: ObjectIdentifier?
}

@MainActor
final class SupermuxHarnessWebHostView: NSView {
    var onDidMoveToWindow: (() -> Void)?
    var onGeometryChanged: (() -> Void)?
    private(set) var geometryRevision: UInt64 = 0
    private var lastReportedGeometryState: SupermuxHarnessWebHostGeometryState?
    private var hasPendingGeometryNotification = false
    private weak var hostedWebView: WKWebView?
    private var sessionContentWidthPresentation = SessionContentWidthPresentation.disabled
    private var pendingScrollDelta = CGPoint.zero
    private var scrollFlushTask: Task<Void, Never>?
    private var isScrollJavaScriptInFlight = false
    private var scrollGeneration: UInt64 = 0
    private static let maximumPendingScrollDelta: CGFloat = 2400

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onDidMoveToWindow?()
        notifyGeometryChangedIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        notifyGeometryChangedIfNeeded()
    }

    override func layout() {
        super.layout()
        if let hostedWebView, hostedWebView.superview === self {
            hostedWebView.frame = sessionContentWidthPresentation.contentFrame(in: bounds)
        }
        notifyGeometryChangedIfNeeded()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        hostedWebView?.acceptsFirstMouse(for: event) ?? false
    }

    override func mouseDown(with event: NSEvent) {
        guard let webView = hostedWebView as? SupermuxHarnessWebView else {
            super.mouseDown(with: event)
            return
        }
        webView.onPointerDown?()
        window?.makeFirstResponder(webView)
    }

    override func scrollWheel(with event: NSEvent) {
        guard hostedWebView != nil else {
            super.scrollWheel(with: event)
            return
        }
        let pointScale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 20
        let deltaX = event.scrollingDeltaX * pointScale
        let deltaY = event.scrollingDeltaY * pointScale
        guard deltaX.isFinite, deltaY.isFinite else {
            super.scrollWheel(with: event)
            return
        }

        pendingScrollDelta.x = Self.clampedScrollDelta(pendingScrollDelta.x + deltaX)
        pendingScrollDelta.y = Self.clampedScrollDelta(pendingScrollDelta.y + deltaY)
        scheduleScrollFlush()
    }

    private static func clampedScrollDelta(_ value: CGFloat) -> CGFloat {
        min(max(value, -maximumPendingScrollDelta), maximumPendingScrollDelta)
    }

    private func scheduleScrollFlush() {
        guard pendingScrollDelta != .zero,
              scrollFlushTask == nil,
              !isScrollJavaScriptInFlight else { return }
        scrollFlushTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.scrollFlushTask = nil
            self.flushPendingScroll()
        }
    }

    private func flushPendingScroll() {
        guard !isScrollJavaScriptInFlight,
              let hostedWebView,
              pendingScrollDelta != .zero else { return }

        let delta = pendingScrollDelta
        pendingScrollDelta = .zero
        isScrollJavaScriptInFlight = true
        let generation = scrollGeneration

        let script = """
        (() => {
          const thread = document.querySelector('.harness-scroll');
          if (!(thread instanceof HTMLElement)) return false;
          thread.scrollBy(\(-Double(delta.x)), \(-Double(delta.y)));
          return true;
        })()
        """
        hostedWebView.evaluateJavaScript(script) { [weak self, weak hostedWebView] _, _ in
            Task { @MainActor in
                guard let self,
                      self.scrollGeneration == generation,
                      self.hostedWebView === hostedWebView else { return }
                self.isScrollJavaScriptInFlight = false
                self.scheduleScrollFlush()
            }
        }
    }

    private func resetPendingScroll() {
        scrollGeneration &+= 1
        scrollFlushTask?.cancel()
        scrollFlushTask = nil
        pendingScrollDelta = .zero
        isScrollJavaScriptInFlight = false
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        markGeometryDirtyIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        markGeometryDirtyIfNeeded()
    }

    private func currentGeometryState() -> SupermuxHarnessWebHostGeometryState {
        SupermuxHarnessWebHostGeometryState(
            frame: frame,
            bounds: bounds,
            windowNumber: window?.windowNumber,
            superviewID: superview.map(ObjectIdentifier.init)
        )
    }

    private func markGeometryDirtyIfNeeded() {
        let state = currentGeometryState()
        guard state != lastReportedGeometryState else { return }
        guard !hasPendingGeometryNotification else { return }
        hasPendingGeometryNotification = true
        Task { @MainActor [weak self] in
            self?.notifyGeometryChangedIfNeeded()
        }
    }

    private func notifyGeometryChangedIfNeeded() {
        hasPendingGeometryNotification = false
        let state = currentGeometryState()
        guard state != lastReportedGeometryState else { return }
        lastReportedGeometryState = state
        geometryRevision &+= 1
        onGeometryChanged?()
    }

    func attachWebView(_ webView: WKWebView) {
        if hostedWebView !== webView {
            resetPendingScroll()
        }
        if webView.superview !== self {
            webView.removeFromSuperview()
            addSubview(webView, positioned: .above, relativeTo: nil)
        }
        hostedWebView = webView
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = []
        webView.frame = sessionContentWidthPresentation.contentFrame(in: bounds)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func setSessionContentWidthPresentation(_ presentation: SessionContentWidthPresentation) {
        guard sessionContentWidthPresentation != presentation else { return }
        sessionContentWidthPresentation = presentation
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func detachHostedWebViewIfOwned(_ webView: WKWebView?) {
        guard let webView,
              webView.superview === self else {
            return
        }
        webView.removeFromSuperview()
        if hostedWebView === webView {
            resetPendingScroll()
            hostedWebView = nil
        }
    }
}
