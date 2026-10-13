// SUPERMUX:begin runtime-browser-delivery-download-regression
import Foundation
import Testing
@testable import CmuxBrowser

@MainActor
@Suite("Runtime browser delivery: scripted downloads")
struct RuntimeBrowserDeliveryDownloadTests {
    @Test("Invalid and malformed floods retain no pending message payloads")
    func invalidFloodDoesNotAccumulateWhileMainActorCannotSuspend() {
        var payloads: [WeakPayload] = []
        let received = Received()
        for index in 0..<512 {
            let payload = NSMutableString(string: String(repeating: "x", count: 8192))
            payloads.append(WeakPayload(payload))
            let body: [String: Any] = [
                "token": index.isMultiple(of: 2) ? "wrong" : "expected",
                "kind": "malformed",
                "unusedLargePayload": payload
            ]
            receive(body, received: received)
        }
        // Keeping this actor turn uninterrupted holds every deferred delivery.
        #expect(payloads.filter { $0.value != nil }.count == 0)
        #expect(received.downloads.isEmpty)
        #expect(received.subframeIntents.isEmpty)
        #expect(received.rejections.count == 512)
    }

    @Test("Valid-token floods deliver in order without retaining queued payloads")
    func validFloodDoesNotAccumulateWhileMainActorCannotSuspend() {
        let received = Received()
        var payloads: [WeakPayload] = []
        for index in 0..<512 {
            let payload = NSMutableString(string: String(repeating: "x", count: 8192))
            payloads.append(WeakPayload(payload))
            receive([
                "token": "expected", "kind": "url",
                "url": "blob:https://example.com/\(index)",
                "suggestedFilename": "\(index).txt", "unusedLargePayload": payload
            ], received: received)
        }
        #expect(payloads.filter { $0.value != nil }.count == 0)
        #expect(received.downloads.map(\.0) == (0..<512).map { "blob:https://example.com/\($0)" })
        #expect(received.downloads.map(\.1) == (0..<512).map { "\($0).txt" })
        #expect(received.rejections.isEmpty)
    }

    @Test("URL normalization, data payload limits and subframe admission stay intact")
    func preservesAdmissionAndDownloadValues() {
        let received = Received()
        receive(["token": "expected", "kind": "dataURL", "dataURL": "  data:text/plain,ok  ", "suggestedFilename": "note.txt"], received: received)
        receive(["token": "expected", "kind": "subframeDownloadIntent", "url": " https://example.com/file "], isMainFrame: false, received: received)
        receive(["token": "expected", "kind": "url", "url": "blob:https://example.com/blocked"], isMainFrame: false, received: received)
        receive(["token": "expected", "kind": "dataURL", "dataURL": "data:" + String(repeating: "x", count: 100)], received: received)
        receive(["token": "expected", "kind": "url", "url": "data:" + String(repeating: "x", count: 100)], received: received)
        receive(["token": "wrong", "kind": "url", "url": "blob:https://example.com/wrong"], received: received)
        receive(["token": "expected", "kind": "url", "url": "blob:https://example.com/missing-token"], expectedToken: nil, received: received)
        receive(["token": "expected", "kind": "url", "url": "  "], received: received)
        receive(NSNull(), received: received)
        #expect(received.downloads.count == 1)
        #expect(received.downloads.first?.0 == "data:text/plain,ok")
        #expect(received.downloads.first?.1 == "note.txt")
        #expect(received.subframeIntents == ["https://example.com/file"])
        #expect(received.rejections.count == 5)
    }

    private func receive(_ body: Any, expectedToken: String? = "expected", isMainFrame: Bool = true, received: Received) {
        BrowserScriptedDownloadDelivery(
            expectedToken: expectedToken,
            maximumDataURLCharacters: 100
        ).receive(
            body: body,
            isMainFrame: isMainFrame,
            onDownload: { received.downloads.append(($0.absoluteString, $1)) },
            onSubframeIntent: { received.subframeIntents.append($0.absoluteString) },
            onRejection: { received.rejections.append($0) }
        )
    }

    private final class WeakPayload {
        weak var value: NSObject?
        init(_ value: NSObject) { self.value = value }
    }

    @MainActor
    private final class Received {
        var downloads: [(String, String?)] = []
        var subframeIntents: [String] = []
        var rejections: [String] = []
    }
}
// SUPERMUX:end runtime-browser-delivery-download-regression
