import CmuxCore
import CmuxRemoteWorkspace
import Foundation

/// Browser -> owning Mac on the alias route: every request's line, `Host`,
/// `Origin` and `Referer` go back to `localhost` (dev servers' host checks
/// pass), exactly as upstream's SSH proxy rewrites them, but for every request
/// on the connection, not only the first. A browser keeps a connection alive
/// and sends its next requests on it: Next.js 16's dev server refused each
/// one that still named the alias (403, `blockCrossSiteDEV`), so a page's
/// chunks after the first never loaded and it never hydrated. Each request's
/// method and whether its `Origin` is a loopback one go to the response side
/// (``SupermuxAliasExchange``).
final class SupermuxAliasRequestTransform: SupermuxByteTransform, @unchecked Sendable {
    private let lock = NSLock()
    private var stream = SupermuxHTTPMessageStream(role: .request)
    private let exchange: SupermuxAliasExchange

    init(exchange: SupermuxAliasExchange) {
        self.exchange = exchange
    }

    func transform(_ data: Data, eof: Bool) -> Data {
        let exchange = exchange
        let alias = RemoteLoopbackProxyAlias.aliasHost
        return lock.withLock {
            stream.feed(data, eof: eof, head: { head in
                let parsed = SupermuxHTTPHead(head)
                exchange.sent(SupermuxAliasExchange.Request(
                    method: parsed?.method ?? "", originIsLoopback: parsed?.originIsLoopback ?? false
                ))
                return SupermuxHTTPMessageStream.HeadResult(
                    bytes: RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(data: head, aliasHost: alias),
                    body: parsed?.requestBody ?? .opaque
                )
            }, incompleteHead: { bytes in
                RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(data: bytes, aliasHost: alias, allowIncompleteHeadersAtEOF: true)
            })
        }
    }
}

/// Owning Mac -> browser on the alias route: every response's headers
/// (redirects, cookies, CORS) name the alias again, upstream's
/// `RemoteDaemonProxySession.rewriteRemoteResponseIfNeeded`, for every
/// response on the connection. A response to a request from a page on
/// `localhost` itself (a mirror page loaded as written, whose
/// `SupermuxMirrorLoopbackBridge` sent another port's request through the
/// alias) keeps its `Access-Control-Allow-Origin` as the server wrote it:
/// mapped to the alias it would no longer match the page.
final class SupermuxAliasResponseTransform: SupermuxByteTransform, @unchecked Sendable {
    private let lock = NSLock()
    private var stream = SupermuxHTTPMessageStream(role: .response)
    private let exchange: SupermuxAliasExchange

    init(exchange: SupermuxAliasExchange) {
        self.exchange = exchange
    }

    func transform(_ data: Data, eof: Bool) -> Data {
        let exchange = exchange
        let alias = RemoteLoopbackProxyAlias.aliasHost
        return lock.withLock {
            stream.feed(data, eof: eof, head: { head in
                let parsed = SupermuxHTTPHead(head)
                let status = parsed?.statusCode ?? 0
                // An interim answer (100 Continue, 103 Early Hints) belongs to the
                // request still waiting for its final one.
                let request = (100..<200).contains(status) && status != 101 ? exchange.current() : exchange.answered()
                let rewritten = RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(data: head, aliasHost: alias)
                return SupermuxHTTPMessageStream.HeadResult(
                    bytes: request?.originIsLoopback == true ? Self.keepingAllowOrigin(of: head, in: rewritten) : rewritten,
                    body: parsed?.responseBody(toMethod: request?.method ?? "GET") ?? .opaque
                )
            }, incompleteHead: { $0 })
        }
    }

    /// `rewritten` with the `Access-Control-Allow-Origin` lines of `original`
    /// (upstream's rewriter keeps the head's lines one for one).
    static func keepingAllowOrigin(of original: Data, in rewritten: Data) -> Data {
        let delimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let originalEnd = original.range(of: delimiter), let rewrittenEnd = rewritten.range(of: delimiter),
              let originalHead = String(data: original[..<originalEnd.lowerBound], encoding: .utf8),
              let rewrittenHead = String(data: rewritten[..<rewrittenEnd.lowerBound], encoding: .utf8) else { return rewritten }
        let originalLines = originalHead.components(separatedBy: "\r\n")
        var lines = rewrittenHead.components(separatedBy: "\r\n")
        guard lines.count == originalLines.count else { return rewritten }
        for (index, line) in originalLines.enumerated() where line.lowercased().hasPrefix("access-control-allow-origin:") {
            lines[index] = line
        }
        return Data(lines.joined(separator: "\r\n").utf8) + rewritten[rewrittenEnd.lowerBound...]
    }
}

/// The requests of one alias connection whose final response has not come
/// yet, in order (HTTP/1.1 answers in request order): the response side needs
/// each one's method (a `HEAD` answer has no body) and whether its `Origin` is
/// a loopback one.
final class SupermuxAliasExchange: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let originIsLoopback: Bool
    }

    private let lock = NSLock()
    private var waiting: [Request] = []

    /// A request head went to the owning Mac.
    func sent(_ request: Request) {
        lock.withLock { waiting.append(request) }
    }

    /// The oldest request waiting for its answer (an interim answer's).
    func current() -> Request? {
        lock.withLock { waiting.first }
    }

    /// The oldest request waiting, now answered.
    func answered() -> Request? {
        lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
    }
}

/// One direction of an HTTP/1.x connection, followed message by message so
/// every head can be rewritten: a head is buffered until it is complete
/// (at most ``maxHeadBytes``), then its body passes through as it arrives,
/// framed by `Content-Length` or by its chunks (chunk sizes and trailers are
/// read, never changed). Bytes it cannot frame (no length on a response that
/// ends with the connection, an upgrade to WebSocket, a malformed head or
/// chunk line, anything that is not HTTP/1.x) pass through untouched from
/// there on, as upstream passed every byte after the first head.
struct SupermuxHTTPMessageStream {
    enum Role {
        case request, response
    }

    /// How the body after a head is framed.
    enum Body: Equatable {
        /// None: the next bytes are the next message's head.
        case none
        case length(Int)
        case chunked
        /// Everything after the head, until the connection ends.
        case opaque
    }

    /// What to send for a head, and how its body is framed.
    struct HeadResult {
        let bytes: Data
        let body: Body
    }

    private enum State {
        case head
        case body(remaining: Int)
        case chunkSize
        /// A chunk's data and the CRLF after it.
        case chunkData(remaining: Int)
        case trailers
        case opaque
    }

    static let maxHeadBytes = 64 * 1024
    static let maxLineBytes = 8 * 1024
    private static let headEnd = Data([0x0D, 0x0A, 0x0D, 0x0A])
    private static let lineEnd = Data([0x0D, 0x0A])

    let role: Role
    private var state = State.head
    /// An incomplete head or chunk line, kept for the next bytes.
    private var pending = Data()

    init(role: Role) {
        self.role = role
    }

    /// The bytes to send on for `data`. `head` gets every complete head;
    /// `incompleteHead` gets what is left of one at `eof` or past
    /// ``maxHeadBytes`` (the stream is opaque after it).
    mutating func feed(
        _ data: Data, eof: Bool, head: (Data) -> HeadResult, incompleteHead: (Data) -> Data
    ) -> Data {
        var buffer = pending
        buffer.append(data)
        pending = Data()
        var out = Data()
        var cursor = buffer.startIndex
        let end = buffer.endIndex
        scan: while cursor < end {
            switch state {
            case .opaque:
                out.append(buffer[cursor..<end])
                cursor = end
            case .body(let remaining), .chunkData(let remaining):
                let take = min(remaining, end - cursor)
                out.append(buffer[cursor..<cursor + take])
                cursor += take
                let left = remaining - take
                if case .body = state {
                    state = left == 0 ? .head : .body(remaining: left)
                } else {
                    state = left == 0 ? .chunkSize : .chunkData(remaining: left)
                }
            case .head:
                guard startsLikeHead(buffer[cursor]) else {
                    state = .opaque
                    continue scan
                }
                guard let marker = buffer.range(of: Self.headEnd, in: cursor..<end) else {
                    if end - cursor > Self.maxHeadBytes {
                        out.append(incompleteHead(Data(buffer[cursor..<end])))
                        state = .opaque
                        cursor = end
                    } else {
                        pending = Data(buffer[cursor..<end])
                        cursor = end
                    }
                    break scan
                }
                let result = head(Data(buffer[cursor..<marker.upperBound]))
                out.append(result.bytes)
                cursor = marker.upperBound
                switch result.body {
                case .none, .length(0): state = .head
                case .length(let count): state = .body(remaining: count)
                case .chunked: state = .chunkSize
                case .opaque: state = .opaque
                }
            case .chunkSize, .trailers:
                guard let lineEnd = buffer.range(of: Self.lineEnd, in: cursor..<end) else {
                    if end - cursor > Self.maxLineBytes {
                        state = .opaque
                    } else {
                        pending = Data(buffer[cursor..<end])
                        cursor = end
                    }
                    continue scan
                }
                let line = buffer[cursor..<lineEnd.lowerBound]
                out.append(buffer[cursor..<lineEnd.upperBound])
                cursor = lineEnd.upperBound
                if case .trailers = state {
                    // The empty line ends the trailers and the message.
                    if line.isEmpty { state = .head }
                } else if let size = Self.chunkSize(line) {
                    state = size == 0 ? .trailers : .chunkData(remaining: size + 2)
                } else {
                    state = .opaque
                }
            }
        }
        if eof, !pending.isEmpty {
            if case .head = state {
                out.append(incompleteHead(pending))
            } else {
                out.append(pending)
            }
            pending = Data()
        }
        return out
    }

    /// Whether a head may start with `byte`: a request's method (a token of
    /// letters) or a response's `HTTP/`; CR and LF are allowed before either.
    private func startsLikeHead(_ byte: UInt8) -> Bool {
        if byte == 0x0D || byte == 0x0A { return true }
        switch role {
        case .request: return (0x41...0x5A).contains(byte)
        case .response: return byte == 0x48 // "H"
        }
    }

    /// The size on a chunk line (hex, before any `;` extension), or nil when
    /// it is not one.
    private static func chunkSize(_ line: Data) -> Int? {
        let text = String(decoding: line, as: UTF8.self)
        let digits = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let trimmed = digits.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 15 else { return nil }
        return Int(trimmed, radix: 16)
    }
}

/// The parts of an HTTP/1.x head the alias route needs: its start line and
/// the fields that frame its body.
struct SupermuxHTTPHead {
    let startLine: String
    private let fields: [(name: String, value: String)]

    init?(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n").drop(while: { $0.isEmpty })
        guard let first = lines.first else { return nil }
        startLine = first
        fields = lines.dropFirst().compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            return (name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// A request's method, upper-cased.
    var method: String {
        String(startLine.split(separator: " ", maxSplits: 1).first ?? "").uppercased()
    }

    /// A response's status code.
    var statusCode: Int? {
        let parts = startLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].uppercased().hasPrefix("HTTP/") else { return nil }
        return Int(parts[1])
    }

    /// Whether the request's `Origin` is a loopback one (a page loaded as
    /// written); false without one.
    var originIsLoopback: Bool {
        guard let value = values("origin").first, let host = RemoteLoopbackProxyAlias.normalizeHost(value) else {
            return false
        }
        return RemoteLoopbackProxyAlias.isLoopbackHost(host)
    }

    /// How a request with this head carries its body. One that asks for an
    /// upgrade (WebSocket) or a tunnel ends the HTTP part of the connection.
    var requestBody: SupermuxHTTPMessageStream.Body {
        if ["CONNECT", "PRI"].contains(method) || !values("upgrade").isEmpty { return .opaque }
        return framedBody ?? .none
    }

    /// How a response with this head, to a request with `method`, carries its
    /// body (RFC 9112, section 6.3).
    func responseBody(toMethod method: String) -> SupermuxHTTPMessageStream.Body {
        guard let status = statusCode else { return .opaque }
        if status == 101 { return .opaque }
        if (100..<200).contains(status) || status == 204 || status == 304 || method == "HEAD" { return .none }
        if method == "CONNECT", (200..<300).contains(status) { return .opaque }
        return framedBody ?? .opaque
    }

    /// `Transfer-Encoding` (chunked last) or `Content-Length`; nil with
    /// neither; opaque when they cannot frame it.
    private var framedBody: SupermuxHTTPMessageStream.Body? {
        let codings = list("transfer-encoding")
        if !codings.isEmpty {
            return codings.last?.lowercased() == "chunked" ? .chunked : .opaque
        }
        let lengths = Set(list("content-length"))
        guard !lengths.isEmpty else { return nil }
        guard lengths.count == 1, let length = lengths.first.flatMap({ Int($0) }), length >= 0 else { return .opaque }
        return .length(length)
    }

    private func values(_ name: String) -> [String] {
        fields.filter { $0.name == name }.map(\.value)
    }

    /// A field's comma-separated values, across repeated lines.
    private func list(_ name: String) -> [String] {
        values(name).flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
