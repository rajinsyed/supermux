// SUPERMUX:begin runtime-browser-delivery-download-admission
import Foundation

@MainActor
enum BrowserScriptedDownloadDelivery {
    static func receive(
        body: Any,
        expectedToken: String?,
        isMainFrame: Bool,
        maximumDataURLCharacters: Int,
        onDownload: @MainActor (URL, String?) -> Void,
        onSubframeIntent: @MainActor (URL) -> Void,
        onRejection: @MainActor (String) -> Void
    ) {
        guard let body = body as? [String: Any] else { return }
        // Admission and delivery finish in WebKit's actor turn: no pending payload queue.
        guard let token = body["token"] as? String,
              let expectedToken,
              token == expectedToken else {
            onRejection("browser.scriptdl.message stage=rejectToken")
            return
        }
        guard let kind = body["kind"] as? String, isMainFrame || kind == "subframeDownloadIntent" else { return }
        let suggestedFilename = body["suggestedFilename"] as? String
        let urlString: String?
        switch kind {
        case "subframeDownloadIntent":
            guard let rawURL = body["url"] as? String,
                  let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            onSubframeIntent(url)
            return
        case "url":
            urlString = body["url"] as? String
        case "dataURL":
            urlString = body["dataURL"] as? String
            if let dataURL = urlString, dataURL.count > maximumDataURLCharacters {
                onRejection("browser.scriptdl.message stage=rejectOversizeDataURL chars=\(dataURL.count)")
                return
            }
        default:
            urlString = nil
        }

        guard let rawURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty,
              let url = URL(string: rawURL) else {
            onRejection("browser.scriptdl.message stage=rejectInvalid kind=\(kind)")
            return
        }

        if url.scheme?.caseInsensitiveCompare("data") == .orderedSame,
           rawURL.count > maximumDataURLCharacters {
            onRejection("browser.scriptdl.message stage=rejectOversizeDataURL chars=\(rawURL.count)")
            return
        }

        onDownload(url, suggestedFilename)
    }
}
// SUPERMUX:end runtime-browser-delivery-download-admission
