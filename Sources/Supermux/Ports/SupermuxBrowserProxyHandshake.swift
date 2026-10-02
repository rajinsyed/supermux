import CmuxCore
import Foundation

/// The opening exchange of one connection to a mirror browser's proxy
/// (``SupermuxDeviceBrowserProxy``): SOCKS5 with username/password (RFC 1928,
/// RFC 1929) or HTTP `CONNECT` with `Proxy-Authorization: Basic`, both checked
/// against the proxy's per-launch credential in constant time. It mirrors
/// upstream's `RemoteDaemonProxySession` handshake, which is internal to its
/// package. Plain absolute-URI HTTP proxying is never served, so the proxy is
/// not an open HTTP proxy for other local processes.
///
/// Pure: feed it the client's bytes, send `reply`, and act on `decision`.
///
/// ```swift
/// var handshake = SupermuxBrowserProxyHandshake(credential: credential)
/// let step = handshake.consume(bytes)   // reply: 05 02, decision: .needMore
/// ```
struct SupermuxBrowserProxyHandshake {
    enum Kind: Sendable, Equatable {
        case socks5
        case httpConnect
    }

    /// Where the client asked to go, and the bytes it sent after its request.
    struct Target: Sendable, Equatable {
        let host: String
        let port: Int
        let kind: Kind
        /// Client bytes already read past the request (the start of its stream).
        let pending: Data

        /// The answer that opens the tunnel.
        var successReply: Data {
            switch kind {
            case .socks5: return Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            case .httpConnect: return SupermuxBrowserProxyHandshake.httpReply("200 Connection Established", closes: false)
            }
        }

        /// The answer when the destination cannot be reached.
        var failureReply: Data {
            switch kind {
            case .socks5: return Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            case .httpConnect: return SupermuxBrowserProxyHandshake.httpReply("502 Bad Gateway")
            }
        }
    }

    enum Decision: Equatable {
        /// Send the reply (if any) and read more.
        case needMore
        /// Send the reply, then close.
        case close
        /// Send the reply (if any), then open the target.
        case connect(Target)
    }

    struct Step: Equatable {
        var reply: Data
        var decision: Decision
    }

    private enum Stage {
        case undecided, socksGreeting, socksAuthentication, socksRequest, httpConnect
    }

    /// A handshake larger than this is refused (no browser sends one).
    private static let maximumHandshakeBytes = 64 * 1024

    private let credential: BrowserProxyCredential
    private var buffer: [UInt8] = []
    private var stage = Stage.undecided

    init(credential: BrowserProxyCredential) {
        self.credential = credential
    }

    /// Consumes the client's next bytes. A client may send several handshake
    /// messages at once, so the replies of every complete message are joined.
    mutating func consume(_ bytes: Data) -> Step {
        buffer.append(contentsOf: bytes)
        var reply = Data()
        while true {
            let next: Next
            switch stage {
            case .undecided:
                guard let first = buffer.first else { return Step(reply: reply, decision: .needMore) }
                stage = first == 0x05 ? .socksGreeting : .httpConnect
                continue
            case .socksGreeting: next = socksGreeting()
            case .socksAuthentication: next = socksAuthentication()
            case .socksRequest: next = socksRequest()
            case .httpConnect: next = httpConnect()
            }
            switch next {
            case .incomplete:
                let decision: Decision = buffer.count > Self.maximumHandshakeBytes ? .close : .needMore
                return Step(reply: reply, decision: decision)
            case .advance(let answer):
                reply.append(answer)
            case .finish(let answer, let decision):
                reply.append(answer)
                return Step(reply: reply, decision: decision)
            }
        }
    }

    // MARK: - SOCKS5

    private enum Next {
        case incomplete
        case advance(Data)
        case finish(Data, Decision)
    }

    private mutating func socksGreeting() -> Next {
        guard buffer.count >= 2, buffer.count >= 2 + Int(buffer[1]) else { return .incomplete }
        let total = 2 + Int(buffer[1])
        let methods = buffer[2..<total]
        buffer.removeFirst(total)
        // Only username/password (0x02); "no authentication" is refused even alone.
        guard methods.contains(0x02) else { return .finish(Data([0x05, 0xFF]), .close) }
        stage = .socksAuthentication
        return .advance(Data([0x05, 0x02]))
    }

    private mutating func socksAuthentication() -> Next {
        guard buffer.count >= 2 else { return .incomplete }
        let usernameLength = Int(buffer[1])
        guard buffer.count >= 3 + usernameLength else { return .incomplete }
        let passwordLength = Int(buffer[2 + usernameLength])
        let total = 3 + usernameLength + passwordLength
        guard buffer.count >= total else { return .incomplete }
        let username = Array(buffer[2..<(2 + usernameLength)])
        let password = Array(buffer[(3 + usernameLength)..<total])
        let version = buffer[0]
        buffer.removeFirst(total)
        guard version == 0x01, credential.matches(username: username, password: password) else {
            return .finish(Data([0x01, 0x01]), .close)
        }
        stage = .socksRequest
        return .advance(Data([0x01, 0x00]))
    }

    private mutating func socksRequest() -> Next {
        let generalFailure = Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        guard buffer.count >= 5 else { return .incomplete }
        guard buffer[0] == 0x05 else { return .finish(generalFailure, .close) }
        let command = buffer[1]
        var cursor = 4
        let host: String
        switch buffer[3] {
        case 0x01:
            guard buffer.count >= cursor + 4 + 2 else { return .incomplete }
            host = buffer[cursor..<(cursor + 4)].map { String($0) }.joined(separator: ".")
            cursor += 4
        case 0x03:
            let length = Int(buffer[cursor])
            cursor += 1
            guard buffer.count >= cursor + length + 2 else { return .incomplete }
            host = String(decoding: buffer[cursor..<(cursor + length)], as: UTF8.self)
            cursor += length
        case 0x04:
            guard buffer.count >= cursor + 16 + 2 else { return .incomplete }
            host = Self.ipv6Text(Array(buffer[cursor..<(cursor + 16)]))
            cursor += 16
        default:
            return .finish(generalFailure, .close)
        }
        let port = Int(buffer[cursor]) << 8 | Int(buffer[cursor + 1])
        cursor += 2
        let pending = Data(buffer[cursor...])
        buffer.removeAll()
        guard command == 0x01 else {
            return .finish(Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), .close)
        }
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty, port > 0 else {
            return .finish(generalFailure, .close)
        }
        return .finish(Data(), .connect(Target(host: host, port: port, kind: .socks5, pending: pending)))
    }

    private static func ipv6Text(_ bytes: [UInt8]) -> String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { target in
            for index in 0..<16 { target[index] = bytes[index] }
        }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &text, socklen_t(INET6_ADDRSTRLEN)) != nil else { return "" }
        return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - HTTP CONNECT

    private mutating func httpConnect() -> Next {
        let marker: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let end = Self.firstRange(of: marker, in: buffer) else { return .incomplete }
        let header = String(decoding: buffer[..<end], as: UTF8.self)
        let pending = Data(buffer[(end + marker.count)...])
        buffer.removeAll()
        let lines = header.components(separatedBy: "\r\n")
        guard hasValidProxyAuthorization(lines.dropFirst()) else {
            let reply = Self.httpReply(
                "407 Proxy Authentication Required",
                extraHeaders: ["Proxy-Authenticate: Basic realm=\"cmux\"", "Content-Length: 0"]
            )
            return .finish(reply, .close)
        }
        let parts = (lines.first ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 2, parts[0].uppercased() == "CONNECT",
              let (host, port) = Self.authority(parts[1]) else {
            return .finish(Self.httpReply("400 Bad Request"), .close)
        }
        return .finish(Data(), .connect(Target(host: host, port: port, kind: .httpConnect, pending: pending)))
    }

    private func hasValidProxyAuthorization(_ lines: ArraySlice<String>) -> Bool {
        let prefix = "proxy-authorization:"
        guard let line = lines.first(where: { $0.lowercased().hasPrefix(prefix) }) else { return false }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "basic",
              let decoded = Data(base64Encoded: parts[1].trimmingCharacters(in: .whitespaces)) else { return false }
        let bytes = [UInt8](decoded)
        guard let colon = bytes.firstIndex(of: UInt8(ascii: ":")) else { return false }
        return credential.matches(username: Array(bytes[..<colon]), password: Array(bytes[(colon + 1)...]))
    }

    /// `host:port` or `[v6]:port`.
    private static func authority(_ raw: String) -> (String, Int)? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let host: String
        let portText: Substring
        if text.hasPrefix("[") {
            guard let closing = text.firstIndex(of: "]"),
                  text[text.index(after: closing)...].hasPrefix(":") else { return nil }
            host = String(text[text.index(after: text.startIndex)..<closing])
            portText = text[text.index(closing, offsetBy: 2)...]
        } else {
            guard let colon = text.lastIndex(of: ":") else { return nil }
            host = String(text[..<colon])
            portText = text[text.index(after: colon)...]
        }
        guard !host.isEmpty, let port = Int(portText), (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    private static func firstRange(of marker: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= marker.count else { return nil }
        return (0...(bytes.count - marker.count)).first { bytes[$0..<($0 + marker.count)].elementsEqual(marker) }
    }

    static func httpReply(_ status: String, closes: Bool = true, extraHeaders: [String] = []) -> Data {
        var text = "HTTP/1.1 \(status)\r\nProxy-Agent: cmux\r\n"
        for header in extraHeaders { text += "\(header)\r\n" }
        if closes { text += "Connection: close\r\n" }
        return Data((text + "\r\n").utf8)
    }
}

/// Where a mirror browser's proxied connection goes, by the host it asked for.
enum SupermuxBrowserProxyDestination: Equatable {
    /// The owning Mac's loopback. `rewritesAlias`: the browser used upstream's
    /// `cmux-loopback.localtest.me` alias for `localhost`, so HTTP headers are
    /// rewritten back to localhost both ways.
    case owner(host: String, rewritesAlias: Bool)
    /// Any other host: dialed from this Mac, so public browsing stays here.
    case direct

    init(host: String) {
        if let family = RemoteLoopbackProxyAlias.localhostFamilyHost(
            forAliasHost: host, aliasHost: RemoteLoopbackProxyAlias.aliasHost
        ) {
            self = .owner(host: family, rewritesAlias: true)
        } else if RemoteLoopbackProxyAlias.isLoopbackHost(host) {
            self = .owner(host: RemoteLoopbackProxyAlias.normalizeHost(host) ?? host, rewritesAlias: false)
        } else {
            self = .direct
        }
    }
}
