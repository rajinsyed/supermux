import Foundation

/// The page a mirror's browser shows when the owning Mac's `localhost:<port>`
/// cannot be reached: the proxy answers the browser's request itself with a
/// `502` and this page, so the user sees why instead of WebKit's generic
/// "could not connect" (which would also hide that the request never touched
/// this Mac's own server). Only the `localhost` route explains itself; other
/// proxied connections fail with a bare protocol error.
enum SupermuxBrowserProxyErrorPage {
    enum Reason: String, Sendable {
        case notListening, needsUpdate, offline, unreachable, noDirectLink, busy, denied

        /// Why a tunnel open to the owning Mac failed.
        init(_ error: any Error) {
            guard let failure = error as? SupermuxDeviceTunnelClient.Failure else {
                self = .offline
                return
            }
            switch failure {
            case .unavailable(.needsUpdate): self = .needsUpdate
            case .unavailable(.noDirectLink): self = .noDirectLink
            case .unavailable(.unreachable): self = .unreachable
            case .unavailable: self = .offline
            case .notListening, .failed: self = .notListening
            case .denied: self = .denied
            case .busy: self = .busy
            }
        }
    }

    /// The whole HTTP response: `502 Bad Gateway`, never cached, then closed.
    static func response(reason: Reason, machineName: String, port: Int) -> Data {
        let body = Data(html(reason: reason, machineName: machineName, port: port).utf8)
        let head = "HTTP/1.1 502 Bad Gateway\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func html(reason: Reason, machineName: String, port: Int) -> String {
        let headline = escaped(headline(reason: reason, machineName: machineName, port: port))
        let detail = reason == .notListening ? "<p>\(escaped(text(reason, machineName: machineName)))</p>" : ""
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>\(headline)</title>
        <style>body{font:15px -apple-system,system-ui,sans-serif;margin:18vh auto;max-width:34em;padding:0 24px;\
        color:#555}@media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#bbb}}\
        h1{font-size:20px;font-weight:600;color:CanvasText}</style></head>
        <body><h1>\(headline)</h1>\(detail)</body></html>
        """
    }

    /// The page's title: "localhost:3000 on <Mac> isn't answering" when nothing
    /// listens there, otherwise the reason itself (an update, the link…).
    static func headline(reason: Reason, machineName: String, port: Int) -> String {
        guard reason == .notListening else { return text(reason, machineName: machineName) }
        return String(
            format: String(
                localized: "supermux.ports.page.title",
                defaultValue: "localhost:%1$lld on %2$@ isn't answering"
            ),
            Int64(port), machineName
        )
    }

    private static func text(_ reason: Reason, machineName: String) -> String {
        let format: String
        switch reason {
        case .notListening:
            format = String(
                localized: "supermux.ports.page.notListening",
                defaultValue: "Nothing on %@ is listening on that port. Start the server there, then reload this page."
            )
        case .needsUpdate:
            format = String(
                localized: "supermux.ports.page.needsUpdate",
                defaultValue: "Update Supermux on %@ to open its localhost here."
            )
        case .offline:
            format = String(
                localized: "supermux.ports.page.offline",
                defaultValue: "%@ is offline. Reload this page when it's back."
            )
        case .unreachable:
            format = String(
                localized: "supermux.ports.page.unreachable",
                defaultValue: "Can't reach %@ right now. Reload this page in a moment."
            )
        case .noDirectLink:
            format = String(
                localized: "supermux.ports.page.noDirectLink",
                defaultValue: "Opening localhost on %@ needs a direct connection to it."
            )
        case .busy:
            format = String(
                localized: "supermux.ports.page.busy",
                defaultValue: "%@ has too many connections open. Reload this page in a moment."
            )
        case .denied:
            format = String(
                localized: "supermux.ports.page.denied",
                defaultValue: "%@ didn't allow this connection."
            )
        }
        return String(format: format, machineName)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
