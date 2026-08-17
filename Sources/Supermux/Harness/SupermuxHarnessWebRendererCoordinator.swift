import AppKit
import SupermuxKit
import UniformTypeIdentifiers
import WebKit

@MainActor
final class SupermuxHarnessWebRendererCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    var webView: SupermuxHarnessWebView?
    private(set) var panelId = UUID()
    private(set) var workspaceId = UUID()
    private(set) var theme: AgentSessionWebTheme = .resolve(
        appearance: .fromConfig(GhosttyConfig.load())
    )
    private var trustedShellURL: URL?
    private var hasLoadedShell = false
    private var hasFinishedNavigation = false
    private var hasCompletedVisiblePaintFlush = false
    private(set) var isPanelFocused = false
    private var isClosed = false
    private(set) var sessionController: SupermuxHarnessSessionController?
    private var pendingEvents: [[String: Any]] = []
    private var eventFlushTask: Task<Void, Never>?
    nonisolated private static let eventFlushIntervalNanoseconds: UInt64 = 33_000_000
    nonisolated private static let eventFlushMaxBatch = 64
    nonisolated static let imagePreviewMaxBytes = 512 * 1024
    nonisolated static let imagePreviewTotalMaxBytes = 2 * 1024 * 1024

    var onSessionStateChanged: ((Bool) -> Void)?
    var onSessionTitleChanged: ((String?) -> Void)?
    var onRestoreStateRetired: (() -> Void)?

    var persistedSnapshot: SessionSupermuxHarnessPanelSnapshot {
        sessionController?.snapshot ?? SessionSupermuxHarnessPanelSnapshot()
    }

    func bind(
        panelId: UUID,
        workspaceId: UUID,
        workingDirectory: String?,
        restoreState: SessionSupermuxHarnessPanelSnapshot?,
        theme: AgentSessionWebTheme,
        isFocused: Bool
    ) {
        self.panelId = panelId
        self.workspaceId = workspaceId
        isPanelFocused = isFocused
        let themeChanged = self.theme != theme
        self.theme = theme
        if themeChanged {
            enqueueEvent(["kind": "theme", "theme": theme.dictionary])
        }
        guard sessionController == nil else { return }
        let controller = SupermuxHarnessSessionController(
            workingDirectory: workingDirectory,
            restoreState: restoreState
        )
        controller.eventSink = { [weak self] event in
            self?.enqueueEvent(event)
        }
        controller.runningStateSink = { [weak self] isRunning in
            self?.onSessionStateChanged?(isRunning)
        }
        controller.titleSink = { [weak self] title in
            self?.onSessionTitleChanged?(title)
        }
        controller.restoreStateRetirementSink = { [weak self] in
            self?.onRestoreStateRetired?()
        }
        sessionController = controller
    }

    func ensureWebView(onPointerDown: @escaping () -> Void) -> SupermuxHarnessWebView {
        if let webView {
            webView.onPointerDown = onPointerDown
            return webView
        }

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        configuration.userContentController.addScriptMessageHandler(
            self,
            contentWorld: .page,
            name: SupermuxHarnessBridgeContract.handlerName
        )
        let webView = SupermuxHarnessWebView(frame: .zero, configuration: configuration)
        isClosed = false
        webView.onPointerDown = onPointerDown
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(macOS 13.3, *) {
#if DEBUG
            webView.isInspectable = true
#else
            webView.isInspectable = false
#endif
        }
        self.webView = webView
        return webView
    }

    func loadShellIfNeeded() {
        guard !hasLoadedShell else { return }
        guard let webView, webView.window != nil else { return }
        guard let resourceDirectoryURL = Bundle.main.resourceURL else { return }
        let indexURL = Self.shellURL(resourceDirectoryURL: resourceDirectoryURL)
        trustedShellURL = Self.normalizedTrustedFileURL(indexURL)
        webView.loadFileURL(indexURL, allowingReadAccessTo: resourceDirectoryURL)
        hasLoadedShell = true
        hasFinishedNavigation = false
        hasCompletedVisiblePaintFlush = false
    }

    func focus() {
        guard let webView else { return }
        _ = webView.window?.makeFirstResponder(webView)
    }

    func unfocus() {
        guard let webView,
              let window = webView.window,
              Self.responderChainContains(window.firstResponder, target: webView) else {
            return
        }
        window.makeFirstResponder(nil)
    }

    func close() {
        isClosed = true
        eventFlushTask?.cancel()
        eventFlushTask = nil
        pendingEvents.removeAll()
        sessionController?.close()
        if let webView {
            webView.removeFromSuperview()
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: SupermuxHarnessBridgeContract.handlerName,
                contentWorld: .page
            )
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.onPointerDown = nil
        }
        webView = nil
        hasLoadedShell = false
        trustedShellURL = nil
        hasFinishedNavigation = false
        hasCompletedVisiblePaintFlush = false
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard isTrustedBridgeFrame(message.frameInfo) else {
            replyHandler(["ok": false, "error": [:]], nil)
            return
        }
        Task { @MainActor in
            do {
                let request = try SupermuxHarnessBridgeRequest(body: message.body)
                let reply = try await self.handle(request)
                replyHandler(["ok": true, "value": reply], nil)
            } catch let error as AgentExecutableResolverError {
                replyHandler(
                    ["ok": false, "error": ["code": "cliUnavailable", "userMessage": error.message]],
                    nil
                )
            } catch let error as SupermuxHarnessBridgeError {
                replyHandler(
                    ["ok": false, "error": ["code": error.code, "userMessage": error.localizedDescription]],
                    nil
                )
            } catch {
                replyHandler(["ok": false, "error": [:]], nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasFinishedNavigation = true
        enqueueEvent(["kind": "theme", "theme": theme.dictionary])
        if isPanelFocused {
            focus()
        }
        flushInitialPaint(for: webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let isMainFrameNavigation = navigationAction.targetFrame?.isMainFrame ?? true
        guard isMainFrameNavigation else {
            decisionHandler(.allow)
            return
        }

        if Self.isTrustedShellURL(url, expected: trustedShellURL) {
            decisionHandler(.allow)
            return
        }

        if isInPageFragment(url, currentURL: webView.url) {
            decisionHandler(.allow)
            return
        }

        if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
            handleExternalLink(url)
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            handleExternalLink(url)
        }
        return nil
    }

    func flushVisiblePaintIfReady() {
        guard hasFinishedNavigation,
              !hasCompletedVisiblePaintFlush,
              let webView,
              webView.window != nil,
              !webView.bounds.isEmpty else {
            return
        }
        flushInitialPaint(for: webView) { [weak self] in
            self?.hasCompletedVisiblePaintFlush = true
        }
    }

    private func flushInitialPaint(for webView: WKWebView, completion: (() -> Void)? = nil) {
        // Retained WKWebViews can finish loading before Bonsplit reattaches them
        // to a visible host. Reading layout after navigation forces WebKit to
        // commit the first page layer once the view is back in the pane.
        let script = """
        (() => {
          void (document.body && document.body.innerText);
          void (document.documentElement && document.documentElement.scrollHeight);
          return true;
        })()
        """
        webView.evaluateJavaScript(script) { result, error in
            _ = result
            _ = error
            webView.setNeedsDisplay(webView.bounds)
            completion?()
        }
    }

    private func enqueueEvent(_ event: [String: Any]) {
        guard !isClosed else { return }
        pendingEvents.append(event)
        if pendingEvents.count >= Self.eventFlushMaxBatch {
            flushPendingEvents()
            return
        }
        guard eventFlushTask == nil else { return }
        eventFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.eventFlushIntervalNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.eventFlushTask = nil
            self.flushPendingEvents()
        }
    }

    private func flushPendingEvents() {
        eventFlushTask?.cancel()
        eventFlushTask = nil
        guard !pendingEvents.isEmpty,
              let webView,
              hasFinishedNavigation,
              let data = try? JSONSerialization.data(withJSONObject: pendingEvents),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        pendingEvents.removeAll()
        webView.evaluateJavaScript("window.supermuxHarness?.receiveBatch(\(json));") { _, error in
            _ = error
        }
    }

    private func isTrustedBridgeFrame(_ frameInfo: WKFrameInfo) -> Bool {
        guard frameInfo.isMainFrame else {
            return false
        }
        return Self.isTrustedShellURL(frameInfo.request.url, expected: trustedShellURL)
    }

    nonisolated static func shellURL(resourceDirectoryURL: URL) -> URL {
        resourceDirectoryURL
            .appendingPathComponent(SupermuxHarnessBridgeContract.resourceDirectoryName, isDirectory: true)
            .appendingPathComponent(SupermuxHarnessBridgeContract.resourceIndexFileName, isDirectory: false)
    }

    nonisolated static func isTrustedShellURL(_ candidate: URL?, expected: URL?) -> Bool {
        guard let candidate = normalizedTrustedFileURL(candidate),
              let expected = normalizedTrustedFileURL(expected) else {
            return false
        }
        return candidate == expected
    }

    nonisolated static func normalizedTrustedFileURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else {
            return nil
        }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func handleExternalLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "mailto" else {
            return
        }

        guard scheme == "http" || scheme == "https" else {
            NSWorkspace.shared.open(url)
            return
        }

        guard let app = AppDelegate.shared,
              let location = app.workspaceContainingPanel(
                  panelId: panelId,
                  preferredWorkspaceId: workspaceId
              ),
              let paneId = location.workspace.paneId(forPanelId: panelId) else {
            NSWorkspace.shared.open(url)
            return
        }

        _ = location.workspace.newBrowserSurface(
            inPane: paneId,
            url: url,
            focus: true
        )
    }

    private func isInPageFragment(_ url: URL, currentURL: URL?) -> Bool {
        guard url.fragment != nil else { return false }
        if (url.scheme == nil || url.scheme == "about"), (url.host ?? "").isEmpty {
            return true
        }
        guard let currentURL else { return false }
        if url.isFileURL, currentURL.isFileURL {
            return (url.path as NSString).standardizingPath ==
                (currentURL.path as NSString).standardizingPath
        }
        return url.scheme == currentURL.scheme &&
            url.host == currentURL.host &&
            url.path == currentURL.path
    }

    private static func responderChainContains(_ responder: NSResponder?, target: NSResponder) -> Bool {
        var current = responder
        while let item = current {
            if item === target {
                return true
            }
            current = item.nextResponder
        }
        return false
    }
}
