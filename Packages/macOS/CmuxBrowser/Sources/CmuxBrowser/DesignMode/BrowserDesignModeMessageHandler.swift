public import Foundation
public import WebKit

/// Converts WebKit message bodies to Sendable data before entering the UI owner.
public final class BrowserDesignModeMessageHandler: NSObject, WKScriptMessageHandler {
    public static let name = "cmuxDesignMode"

    private let onSnapshot: @MainActor @Sendable (Data) -> Void
    private let onExitRequested: @MainActor @Sendable () -> Void
    private let onPromptReset: @MainActor @Sendable () -> Void
    private let onInteractionModeChanged: @MainActor @Sendable (String) -> Void
    private let onAnnotationDrawing: @MainActor @Sendable (String) -> Void
    private let onAnnotationCancelled: @MainActor @Sendable (String) -> Void
    private let onAnnotationCaptureRequested: @MainActor @Sendable (Data) -> Void

    public init(
        onSnapshot: @escaping @MainActor @Sendable (Data) -> Void,
        onExitRequested: @escaping @MainActor @Sendable () -> Void = {},
        onPromptReset: @escaping @MainActor @Sendable () -> Void = {},
        onInteractionModeChanged: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onAnnotationDrawing: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onAnnotationCancelled: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onAnnotationCaptureRequested: @escaping @MainActor @Sendable (Data) -> Void = { _ in }
    ) {
        self.onSnapshot = onSnapshot
        self.onExitRequested = onExitRequested
        self.onPromptReset = onPromptReset
        self.onInteractionModeChanged = onInteractionModeChanged
        self.onAnnotationDrawing = onAnnotationDrawing
        self.onAnnotationCancelled = onAnnotationCancelled
        self.onAnnotationCaptureRequested = onAnnotationCaptureRequested
    }

    // SUPERMUX:begin runtime-browser-delivery-design-receive
    @MainActor
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        receive(name: message.name, isMainFrame: message.frameInfo.isMainFrame, body: message.body)
    }

    @MainActor
    func receive(name: String, isMainFrame: Bool, body: Any) {
        // WKScriptMessageHandler delivers on MainActor; keep causal messages in this turn.
        guard name == Self.name,
              isMainFrame,
              let body = body as? [String: Any],
              let type = body["type"] as? String else { return }
        if type == "exit_requested" {
            onExitRequested()
            return
        }
        if type == "prompt_reset" {
            onPromptReset()
            return
        }
        if type == "interaction_mode_changed", let mode = body["mode"] as? String {
            onInteractionModeChanged(mode)
            return
        }
        if type == "annotation_drawing", let id = body["id"] as? String {
            onAnnotationDrawing(id)
            return
        }
        if type == "annotation_cancelled", let id = body["id"] as? String {
            onAnnotationCancelled(id)
            return
        }
        if type == "annotation_capture_requested",
           let request = body["request"],
           JSONSerialization.isValidJSONObject(request),
           let data = try? JSONSerialization.data(withJSONObject: request) {
            onAnnotationCaptureRequested(data)
            return
        }
        guard type == "snapshot",
              let snapshot = body["snapshot"],
              JSONSerialization.isValidJSONObject(snapshot),
              let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }
        onSnapshot(data)
    }
    // SUPERMUX:end runtime-browser-delivery-design-receive
}
