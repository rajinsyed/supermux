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
    let ownershipGeneration: UInt64
    var onDidMoveToWindow: (() -> Void)?
    var onGeometryChanged: (() -> Void)?
    private(set) var geometryRevision: UInt64 = 0
    private var lastReportedGeometryState: SupermuxHarnessWebHostGeometryState?
    private var hasPendingGeometryNotification = false
    private var isCompositorPresentationVisible = false
    private weak var hostedWebView: WKWebView?
    private var sessionContentWidthPresentation = SessionContentWidthPresentation.disabled
    private var pendingScrollDelta = CGPoint.zero
    private var scrollFlushTask: Task<Void, Never>?
    private var isScrollJavaScriptInFlight = false
    private var scrollGeneration: UInt64 = 0
    private static let maximumPendingScrollDelta: CGFloat = 2400

    init(ownershipGeneration: UInt64) {
        self.ownershipGeneration = ownershipGeneration
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isCompositorPresentationVisible else { return nil }
        return super.hitTest(point)
    }

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

        // The pane can hold more than one `.harness-scroll` at a time: the view
        // router swaps the transcript area between the main chat, an agent
        // chat, a shell tail and the workflow browser, and a branch that is
        // mounted but not displayed still answers `querySelector`. Taking the
        // FIRST match scrolled a hidden node and the visible one never moved —
        // the "cant scroll the agents view" report. `offsetParent` is null for
        // anything with no box (display:none, or a detached subtree), so the
        // first match that has one is the scroller actually on screen. The
        // unconditional fallback keeps a `position: fixed` scroller — for which
        // `offsetParent` is also null — working rather than silently inert.
        let script = """
        (() => {
          const all = document.querySelectorAll('.harness-scroll');
          let thread = null;
          for (const node of all) {
            if (node instanceof HTMLElement && node.offsetParent !== null) {
              thread = node;
              break;
            }
          }
          if (thread === null) thread = all[0];
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

    func setCompositorPresentationVisible(_ visible: Bool) {
        isCompositorPresentationVisible = visible
        wantsLayer = true
        layer?.opacity = visible ? 1 : 0
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

    func relinquishHostedWebView(_ webView: WKWebView?) {
        guard let webView, hostedWebView === webView else { return }
        resetPendingScroll()
        hostedWebView = nil
    }

    func detachHostedWebViewIfOwned(_ webView: WKWebView?) {
        guard let webView,
              webView.superview === self else {
            return
        }
        webView.removeFromSuperview()
        relinquishHostedWebView(webView)
    }
}
