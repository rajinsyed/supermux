import AppKit
import SupermuxKit
import UniformTypeIdentifiers
import WebKit

@MainActor
final class SupermuxHarnessWebRendererCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    private let sessionRepository: any SupermuxHarnessSessionReading
    private let transcriptService: any SupermuxHarnessSubagentTranscriptLoading
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
    private var shellRecoveryTask: Task<Void, Never>?
    private var consecutiveShellRecoveryAttempts = 0
    private(set) var isPanelFocused = false
    private var isPresentationVisible = true
    private var isClosed = false
    private(set) var sessionController: SupermuxHarnessSessionController?
    private let eventTransport = SupermuxHarnessNativeEventTransport()
    private let hostOwnership = SupermuxHarnessWebHostOwnership()
    private var eventFlushTask: Task<Void, Never>?
    private var activeEventDeliveryID: UUID?
    private var nextEventIngressTicket: UInt64 = 1
    private var servingEventIngressTicket: UInt64 = 1
    private var eventIngressWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var completedEventIngressTickets = Set<UInt64>()
    private var backlogSpaceWaiters: [CheckedContinuation<Void, Never>] = []
    private var backpressuredEventCount = 0
    private var presentationDeliveryTask: Task<Void, Never>?
    private var activePresentationDeliveryID: UUID?
    private var presentationRevision: UInt64 = 1
    private var deliveredPresentationRevision: UInt64 = 0
    nonisolated private static let deliveryRetryIntervalNanoseconds: UInt64 = 33_000_000
    nonisolated private static let shellRecoveryDelayNanoseconds: UInt64 = 100_000_000
    nonisolated private static let maximumConsecutiveShellRecoveryAttempts = 3
    nonisolated static let imagePreviewMaxBytes = 512 * 1024
    nonisolated static let imagePreviewTotalMaxBytes = 2 * 1024 * 1024

    var onSessionStateChanged: ((Bool) -> Void)?
    var onSessionTitleChanged: ((String?) -> Void)?
    var onPendingUserInputChanged: ((Bool) -> Void)?
    var onRestoreStateRetired: (() -> Void)?

    init(
        sessionRepository: any SupermuxHarnessSessionReading,
        transcriptService: any SupermuxHarnessSubagentTranscriptLoading
    ) {
        self.sessionRepository = sessionRepository
        self.transcriptService = transcriptService
        super.init()
    }

    var persistedSnapshot: SessionSupermuxHarnessPanelSnapshot {
        sessionController?.snapshot ?? SessionSupermuxHarnessPanelSnapshot()
    }

    private var isPresentationCommitted: Bool {
        isPresentationVisible && deliveredPresentationRevision == presentationRevision
    }

    func bind(
        panelId: UUID,
        workspaceId: UUID,
        workingDirectory: String?,
        restoreState: SessionSupermuxHarnessPanelSnapshot?,
        theme: AgentSessionWebTheme,
        isFocused: Bool,
        isPresentationVisible: Bool
    ) {
        self.panelId = panelId
        self.workspaceId = workspaceId
        isPanelFocused = isFocused && isPresentationVisible
        setPresentationVisible(isPresentationVisible)
        let themeChanged = self.theme != theme
        self.theme = theme
        if themeChanged {
            enqueueEventSoon(["kind": "theme", "theme": theme.dictionary])
        }
        guard sessionController == nil else { return }
        let controller = SupermuxHarnessSessionController(
            workingDirectory: workingDirectory,
            restoreState: restoreState,
            sessionRepository: sessionRepository,
            transcriptService: transcriptService
        )
        controller.eventSink = { [weak self] event in
            await self?.enqueueEvent(event)
        }
        controller.runningStateSink = { [weak self] isRunning in
            self?.onSessionStateChanged?(isRunning)
        }
        controller.titleSink = { [weak self] title in
            self?.onSessionTitleChanged?(title)
        }
        controller.pendingUserInputSink = { [weak self] needsInput in
            self?.onPendingUserInputChanged?(needsInput)
        }
        controller.turnCompletedSink = { [weak self] frame in
            self?.postTurnCompleteNotificationIfUnfocused(frame)
        }
        controller.permissionPromptSink = { [weak self] toolName in
            self?.postPermissionNotificationIfUnfocused(toolName: toolName)
        }
        controller.restoreStateRetirementSink = { [weak self] in
            self?.onRestoreStateRetired?()
        }
        sessionController = controller
    }

    func issueHostGeneration() -> UInt64 {
        hostOwnership.issueGeneration()
    }

    func claimHost(_ host: SupermuxHarnessWebHostView) -> Bool {
        let previousHost = hostOwnership.owner as? SupermuxHarnessWebHostView
        guard hostOwnership.claim(host, generation: host.ownershipGeneration) else {
            return false
        }
        if previousHost !== host {
            previousHost?.relinquishHostedWebView(webView)
        }
        host.setCompositorPresentationVisible(isPresentationCommitted)
        return true
    }

    func attachWebView(_ webView: WKWebView, to host: SupermuxHarnessWebHostView) {
        guard hostOwnership.owns(host, generation: host.ownershipGeneration) else { return }
        host.attachWebView(webView)
    }

    func releaseHost(_ host: SupermuxHarnessWebHostView) {
        guard hostOwnership.release(host, generation: host.ownershipGeneration) else { return }
        host.detachHostedWebViewIfOwned(webView)
    }

    func hostDidMoveToWindow(_ host: SupermuxHarnessWebHostView?) {
        guard let host,
              hostOwnership.owns(host, generation: host.ownershipGeneration) else {
            return
        }
        loadShellIfNeeded()
        flushVisiblePaintIfReady()
    }

    func hostGeometryDidChange(_ host: SupermuxHarnessWebHostView?) {
        guard let host,
              hostOwnership.owns(host, generation: host.ownershipGeneration) else {
            return
        }
        flushVisiblePaintIfReady()
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
        guard isPresentationCommitted, let webView else { return }
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
        presentationDeliveryTask?.cancel()
        presentationDeliveryTask = nil
        shellRecoveryTask?.cancel()
        shellRecoveryTask = nil
        activeEventDeliveryID = nil
        activePresentationDeliveryID = nil
        eventTransport.discardAll()
        resumeEventIngressWaiters()
        resumeBacklogSpaceWaiters()
        sessionController?.close()
        if let owner = hostOwnership.owner as? SupermuxHarnessWebHostView {
            owner.relinquishHostedWebView(webView)
        }
        hostOwnership.reset()
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        hasFinishedNavigation = false
        hasCompletedVisiblePaintFlush = false
        eventFlushTask?.cancel()
        eventFlushTask = nil
        activeEventDeliveryID = nil
        activePresentationDeliveryID = nil
        presentationDeliveryTask?.cancel()
        presentationDeliveryTask = nil
        _ = eventTransport.beginDocumentNavigation()
        presentationRevision &+= 1
        deliveredPresentationRevision = 0
        setHostCompositorPresentationVisible(false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        shellRecoveryTask?.cancel()
        shellRecoveryTask = nil
        consecutiveShellRecoveryAttempts = 0
        hasFinishedNavigation = true
        scheduleEventFlush()
        if !isPresentationVisible {
            schedulePresentationDelivery()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.enqueueEvent(["kind": "theme", "theme": self.theme.dictionary])
            self.schedulePresentationDelivery()
        }
        if isPanelFocused {
            focus()
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        _ = navigation
        _ = error
        scheduleShellRecovery(for: webView, delayed: true)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        _ = navigation
        _ = error
        scheduleShellRecovery(for: webView, delayed: true)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        scheduleShellRecovery(for: webView, delayed: false)
    }

    private func scheduleShellRecovery(for webView: WKWebView, delayed: Bool) {
        guard webView === self.webView,
              !isClosed,
              consecutiveShellRecoveryAttempts < Self.maximumConsecutiveShellRecoveryAttempts else {
            return
        }
        consecutiveShellRecoveryAttempts += 1
        hasLoadedShell = false
        hasFinishedNavigation = false
        hasCompletedVisiblePaintFlush = false
        eventFlushTask?.cancel()
        eventFlushTask = nil
        presentationDeliveryTask?.cancel()
        presentationDeliveryTask = nil
        activeEventDeliveryID = nil
        activePresentationDeliveryID = nil
        setHostCompositorPresentationVisible(false)
        shellRecoveryTask?.cancel()
        shellRecoveryTask = Task { @MainActor [weak self, weak webView] in
            if delayed {
                try? await Task.sleep(nanoseconds: Self.shellRecoveryDelayNanoseconds)
            }
            guard !Task.isCancelled,
                  let self,
                  let webView,
                  webView === self.webView,
                  !self.isClosed else {
                return
            }
            self.shellRecoveryTask = nil
            self.loadShellIfNeeded()
        }
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

        if let shouldAllow = Self.shouldAllowShellNavigation(
            url,
            currentURL: webView.url,
            expected: trustedShellURL,
            hasFinishedNavigation: hasFinishedNavigation
        ) {
            decisionHandler(shouldAllow ? .allow : .cancel)
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
        guard isPresentationCommitted,
              hasFinishedNavigation,
              !hasCompletedVisiblePaintFlush,
              let webView,
              webView.window != nil,
              !webView.bounds.isEmpty else {
            return
        }
        flushInitialPaint(for: webView) { [weak self] in
            guard let self, self.isPresentationCommitted else { return }
            self.hasCompletedVisiblePaintFlush = true
            self.setHostCompositorPresentationVisible(true)
            if self.isPanelFocused {
                self.focus()
            }
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

    private func enqueueEventSoon(_ event: [String: Any]) {
        Task { @MainActor [weak self] in
            await self?.enqueueEvent(event)
        }
    }

    private func enqueueEvent(_ event: [String: Any]) async {
        let ticket = nextEventIngressTicket
        nextEventIngressTicket &+= 1
        if ticket != servingEventIngressTicket {
            await withCheckedContinuation { continuation in
                eventIngressWaiters[ticket] = continuation
            }
        }
        defer { finishEventIngress(ticket: ticket) }
        guard !isClosed else { return }
        await enqueueEventInOrder(event)
    }

    private func enqueueEventInOrder(_ event: [String: Any]) async {
        var isBackpressured = false
        defer {
            if isBackpressured {
                backpressuredEventCount -= 1
                if backpressuredEventCount == 0 {
                    schedulePresentationDelivery()
                }
            }
        }

        while !isClosed {
            switch eventTransport.enqueue(event) {
            case .accepted:
                scheduleEventFlush()
                return
            case .eventTooLarge:
#if DEBUG
                NSLog("SupermuxHarness dropped an event that exceeds the native bridge envelope limit")
#endif
                return
            case .recoveryRequired:
                break
            }
            if !isBackpressured {
                isBackpressured = true
                backpressuredEventCount += 1
            }
            await withCheckedContinuation { continuation in
                backlogSpaceWaiters.append(continuation)
            }
        }
    }

    private func finishEventIngress(ticket: UInt64) {
        if ticket == servingEventIngressTicket {
            servingEventIngressTicket &+= 1
            while completedEventIngressTickets.remove(servingEventIngressTicket) != nil {
                servingEventIngressTicket &+= 1
            }
            eventIngressWaiters.removeValue(forKey: servingEventIngressTicket)?.resume()
        } else {
            completedEventIngressTickets.insert(ticket)
        }
    }

    private func resumeEventIngressWaiters() {
        let waiters = Array(eventIngressWaiters.values)
        eventIngressWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func scheduleEventFlush() {
        guard !isClosed,
              eventFlushTask == nil,
              activeEventDeliveryID == nil,
              eventTransport.pendingEventCount > 0 else {
            return
        }
        eventFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.deliveryRetryIntervalNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.eventFlushTask = nil
            self.flushPendingEvents()
        }
    }

    private func flushPendingEvents() {
        eventFlushTask?.cancel()
        eventFlushTask = nil
        guard activeEventDeliveryID == nil,
              let webView,
              hasFinishedNavigation,
              isPresentationVisible || deliveredPresentationRevision == presentationRevision,
              let envelope = eventTransport.nextEnvelope(),
              let data = envelope.encodedData,
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        let deliveryID = UUID()
        activeEventDeliveryID = deliveryID
        let script = "window.supermuxHarness?.receiveEnvelope(\(json));"
        webView.evaluateJavaScript(script) { [weak self] result, error in
            Task { @MainActor in
                self?.completeEventDelivery(
                    deliveryID: deliveryID,
                    result: result,
                    error: error
                )
            }
        }
    }

    private func completeEventDelivery(deliveryID: UUID, result: Any?, error: (any Error)?) {
        guard activeEventDeliveryID == deliveryID else { return }
        activeEventDeliveryID = nil
        guard error == nil,
              let acknowledgement = SupermuxHarnessNativeEventAcknowledgement(body: result),
              eventTransport.acknowledge(acknowledgement) else {
            eventTransport.deliveryFailed()
            scheduleEventFlush()
            return
        }

        resumeBacklogSpaceWaiters()
        scheduleEventFlush()
        schedulePresentationDelivery()
    }

    private func resumeBacklogSpaceWaiters() {
        let waiters = backlogSpaceWaiters
        backlogSpaceWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func setPresentationVisible(_ visible: Bool) {
        guard isPresentationVisible != visible else {
            if !visible {
                setHostCompositorPresentationVisible(false)
            }
            schedulePresentationDelivery()
            return
        }
        isPresentationVisible = visible
        presentationRevision &+= 1
        hasCompletedVisiblePaintFlush = false
        setHostCompositorPresentationVisible(false)
        if !visible {
            unfocus()
        }
        schedulePresentationDelivery()
    }

    private func setHostCompositorPresentationVisible(_ visible: Bool) {
        guard let host = hostOwnership.owner as? SupermuxHarnessWebHostView,
              hostOwnership.owns(host, generation: host.ownershipGeneration) else {
            return
        }
        host.setCompositorPresentationVisible(visible)
    }

    private func schedulePresentationDelivery() {
        guard !isClosed,
              deliveredPresentationRevision != presentationRevision,
              presentationDeliveryTask == nil,
              activePresentationDeliveryID == nil else {
            return
        }
        presentationDeliveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.deliveryRetryIntervalNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.presentationDeliveryTask = nil
            self.flushPresentationDelivery()
        }
    }

    private func flushPresentationDelivery() {
        presentationDeliveryTask?.cancel()
        presentationDeliveryTask = nil
        guard activePresentationDeliveryID == nil,
              let webView,
              hasFinishedNavigation,
              !isPresentationVisible || backpressuredEventCount == 0 else {
            return
        }

        let revision = presentationRevision
        let epoch = eventTransport.documentEpoch
        let control: [String: Any] = [
            "documentEpoch": epoch,
            "visible": isPresentationVisible,
            "targetSequence": eventTransport.highestEnqueuedSequence,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: control, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        let deliveryID = UUID()
        activePresentationDeliveryID = deliveryID
        let script = "window.supermuxHarness?.setPresentationVisibility(\(json));"
        webView.evaluateJavaScript(script) { [weak self] result, error in
            Task { @MainActor in
                self?.completePresentationDelivery(
                    deliveryID: deliveryID,
                    revision: revision,
                    epoch: epoch,
                    accepted: result as? Bool,
                    error: error
                )
            }
        }
    }

    private func completePresentationDelivery(
        deliveryID: UUID,
        revision: UInt64,
        epoch: String,
        accepted: Bool?,
        error: (any Error)?
    ) {
        guard activePresentationDeliveryID == deliveryID else { return }
        activePresentationDeliveryID = nil
        if error == nil,
           accepted == true,
           revision == presentationRevision,
           epoch == eventTransport.documentEpoch {
            deliveredPresentationRevision = revision
            if isPresentationVisible {
                flushVisiblePaintIfReady()
            } else {
                setHostCompositorPresentationVisible(false)
            }
            scheduleEventFlush()
        }
        schedulePresentationDelivery()
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

    nonisolated static func shouldAllowShellNavigation(
        _ candidate: URL,
        currentURL: URL?,
        expected: URL?,
        hasFinishedNavigation: Bool
    ) -> Bool? {
        if isInPageFragment(candidate, currentURL: currentURL) {
            return true
        }
        guard isTrustedShellURL(candidate, expected: expected) else { return nil }
        // The retained document is the reducer checkpoint. Replacing it after a
        // successful load would discard acknowledged state outside the bounded backlog.
        return !hasFinishedNavigation
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

    nonisolated private static func isInPageFragment(_ url: URL, currentURL: URL?) -> Bool {
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
