// SUPERMUX:begin runtime-browser-delivery-design-regression
import Foundation
import Testing
@testable import CmuxBrowser

@MainActor
@Suite("Runtime browser delivery: design mode")
struct RuntimeBrowserDeliveryDesignTests {
    @Test("Drawing, capture, cancellation and disable are visible in receive order")
    func lifecycleIsDeliveredBeforeTheReceiverCanSuspend() throws {
        let events = Events()
        let handler = BrowserDesignModeMessageHandler(
            onSnapshot: { data in
                let snapshot = try! JSONDecoder().decode(BrowserDesignModeSnapshot.self, from: data)
                events.values.append(snapshot.enabled ? "enabled" : "disabled")
            },
            onExitRequested: { events.values.append("exit") },
            onPromptReset: { events.values.append("reset") },
            onInteractionModeChanged: { events.values.append("mode:\($0)") },
            onAnnotationDrawing: { events.values.append("draw:\($0)") },
            onAnnotationCancelled: { events.values.append("cancel:\($0)") },
            onAnnotationCaptureRequested: { data in
                let request = try! JSONDecoder().decode(BrowserDesignModeAnnotationCaptureRequest.self, from: data)
                events.values.append("capture:\(request.id)")
            }
        )
        let request = BrowserDesignModeAnnotationCaptureRequest(
            id: "second",
            strokeBounds: .init(x: 1, y: 2, width: 20, height: 30),
            viewport: .init(width: 800, height: 600),
            scrollX: 0,
            scrollY: 0
        )
        let snapshot = BrowserDesignModeSnapshot(revision: 1, enabled: false, selection: nil, edits: [], cssDiff: "")
        let messages: [[String: Any]] = [
            ["type": "interaction_mode_changed", "mode": "draw"],
            ["type": "annotation_drawing", "id": "first"],
            ["type": "annotation_cancelled", "id": "first"],
            ["type": "annotation_drawing", "id": "second"],
            ["type": "annotation_capture_requested", "request": try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))],
            ["type": "prompt_reset"],
            ["type": "interaction_mode_changed", "mode": "select"],
            ["type": "snapshot", "snapshot": try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))],
            ["type": "exit_requested"]
        ]
        let expected = ["mode:draw", "draw:first", "cancel:first", "draw:second", "capture:second", "reset", "mode:select", "disabled", "exit"]
        // This uninterrupted actor turn denies queued tasks any scheduling opportunity.
        // Each next receive must see the prior callback's completed mutation.
        for (index, body) in messages.enumerated() {
            handler.receive(name: BrowserDesignModeMessageHandler.name, isMainFrame: true, body: body)
            #expect(events.values == Array(expected.prefix(index + 1)))
        }
    }

    @Test("Foreign names, subframes and malformed messages never reach the owner")
    func rejectsNonProtocolMessages() {
        let events = Events()
        let handler = BrowserDesignModeMessageHandler(onSnapshot: { _ in events.values.append("snapshot") }, onAnnotationDrawing: { events.values.append($0) })
        handler.receive(name: "foreign", isMainFrame: true, body: ["type": "annotation_drawing", "id": "one"])
        handler.receive(name: BrowserDesignModeMessageHandler.name, isMainFrame: false, body: ["type": "annotation_drawing", "id": "two"])
        handler.receive(name: BrowserDesignModeMessageHandler.name, isMainFrame: true, body: ["type": "annotation_drawing", "id": 3])
        #expect(events.values.isEmpty)
    }

    @MainActor
    private final class Events {
        var values: [String] = []
    }
}
// SUPERMUX:end runtime-browser-delivery-design-regression
