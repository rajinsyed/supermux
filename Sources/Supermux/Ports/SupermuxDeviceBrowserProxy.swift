import CmuxCore
import CmuxRemoteWorkspace
import CmuxSurfaceCatalogModel
import Foundation
import Network

/// One remote Mac's browser proxy: what a device mirror's browsers use as
/// their workspace proxy (upstream's remote-workspace browser mode,
/// ``SupermuxDeviceBrowserRoute``), so their `localhost` is that Mac's.
///
/// A SOCKS5 + HTTP `CONNECT` listener on `127.0.0.1:<ephemeral>` that only
/// accepts its own per-launch random credential
/// (``SupermuxBrowserProxyHandshake``). Each connection is routed by the host
/// the browser asked for (``SupermuxBrowserProxyDestination``):
/// - the `cmux-loopback.localtest.me` alias BrowserPanel substitutes for
///   `localhost` in `http` URLs goes to the owning Mac's loopback through the
///   device link's tunnel lanes (``SupermuxDeviceTunnelClient``), with request
///   and response headers rewritten back to `localhost`, as upstream's
///   `RemoteDaemonProxySession` does for SSH workspaces;
/// - a literal loopback host (`https://localhost`, `127.0.0.1`, `[::1]`,
///   `*.localhost` through CONNECT) goes there too, untouched;
/// - every other host is dialed from this Mac, so public sites load here.
///
/// When the owning Mac's `localhost` cannot be reached, the browser gets an
/// explanation page (``SupermuxBrowserProxyErrorPage``) instead of a bare
/// connection error. Its port is registered in ``SupermuxOwnListenerPorts`` so
/// the tunnel host never connects a tunnel back into it.
@MainActor
final class SupermuxDeviceBrowserProxy {
    let machine: SurfaceMachineID
    /// The endpoint browsers use: nil until the first listener is ready. A
    /// failed listener's endpoint stays until its replacement is ready, so
    /// every browser of this Mac, open or new, gets that one meanwhile.
    private(set) var endpoint: BrowserProxyEndpoint?
    /// Dial counters for the E2E (``SupermuxMirrorBrowserSocket``).
    let stats = SupermuxBrowserProxyStats()

    private let credential = BrowserProxyCredential.random()
    /// Gets the endpoint each time a listener is ready.
    private let onEndpointChange: @MainActor (BrowserProxyEndpoint) -> Void
    private var listener: NWListener?
    /// The port registered in ``SupermuxOwnListenerPorts`` for the listener
    /// that became ready, until it fails. Not the kept endpoint's: after a
    /// failure that port may be another listener's.
    private var registeredPort: Int?
    #if DEBUG
    /// E2E (`supermux.devices.mirror.browser_proxy_hold`): while true no new
    /// listener is made, as when `NWListener(using:)` fails, so a failed one
    /// stays down.
    var debugRefusesListener = false
    #endif

    /// The pause before a failed listener is replaced, so a failure that
    /// persists cannot spin.
    private static let restartDelay: Duration = .seconds(1)

    init(machine: SurfaceMachineID, onEndpointChange: @escaping @MainActor (BrowserProxyEndpoint) -> Void) {
        self.machine = machine
        self.onEndpointChange = onEndpointChange
    }

    /// Starts listening unless it already is (or is starting). A listener that
    /// failed is replaced after ``restartDelay``, or on an earlier call.
    func start() {
        guard listener == nil else { return }
        #if DEBUG
        if debugRefusesListener { return }
        #endif
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return }
        self.listener = listener
        let admission = SupermuxBrowserProxyAdmission()
        let connection = SupermuxBrowserProxyConnection(
            machine: machine, credential: credential, stats: stats, admission: admission
        )
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                self.listenerChanged(state, port: listener.port?.rawValue)
            }
        }
        listener.newConnectionHandler = { accepted in
            // Too many clients still in their handshake: refuse this one at once.
            guard admission.admit() else {
                accepted.cancel()
                return
            }
            Task.detached { await connection.serve(accepted) }
        }
        listener.start(queue: .main)
    }

    private func listenerChanged(_ state: NWListener.State, port: UInt16?) {
        switch state {
        case .ready:
            guard let port, port != 0 else { return }
            SupermuxOwnListenerPorts.shared.insert(Int(port))
            registeredPort = Int(port)
            let endpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: Int(port), credential: credential)
            self.endpoint = endpoint
            onEndpointChange(endpoint)
        case .failed:
            // The dead endpoint stays until ready replaces it: the open browsers
            // keep it, and one made meanwhile gets it too, so a refused load for
            // a moment, never one that goes direct from this Mac. An endpoint
            // configures the whole data store this Mac's browsers share, so a
            // new browser given none would take the proxy away from all of them
            // and send their `localhost` here. Only its port stops being ours.
            if let port = registeredPort {
                SupermuxOwnListenerPorts.shared.remove(port)
                registeredPort = nil
            }
            listener?.cancel()
            listener = nil
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.restartDelay)
                self?.start()
            }
        default:
            break
        }
    }
}

#if DEBUG
extension SupermuxDeviceBrowserProxy {
    /// E2E (`supermux.devices.mirror.browser_proxy_fail`): runs what the
    /// network stack failing the listener runs.
    func debugFailListener() {
        listenerChanged(.failed(.posix(.ECONNABORTED)), port: nil)
    }
}
#endif

/// Dial counters of one browser proxy (DEBUG E2E evidence; cheap enough to
/// keep in every build).
final class SupermuxBrowserProxyStats: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (ownerDials: 0, directDials: 0, failures: 0)

    var ownerDials: Int { lock.withLock { counts.ownerDials } }
    var directDials: Int { lock.withLock { counts.directDials } }
    var failures: Int { lock.withLock { counts.failures } }

    func noteOwnerDial() { lock.withLock { counts.ownerDials += 1 } }
    func noteDirectDial() { lock.withLock { counts.directDials += 1 } }
    func noteFailure() { lock.withLock { counts.failures += 1 } }

    #if DEBUG
    /// The newest connections' timelines (E2E evidence, `browser_proxy`).
    private var traces: [SupermuxBrowserProxyTrace] = []
    private var nextTraceID = 0
    private let traceStart = ContinuousClock.now

    func beginTrace() -> Int {
        lock.withLock {
            nextTraceID += 1
            traces.append(SupermuxBrowserProxyTrace(id: nextTraceID, accepted: elapsed()))
            if traces.count > 64 { traces.removeFirst(traces.count - 64) }
            return nextTraceID
        }
    }

    func trace(_ id: Int, _ update: (inout SupermuxBrowserProxyTrace, Double) -> Void) {
        lock.withLock {
            guard let index = traces.firstIndex(where: { $0.id == id }) else { return }
            update(&traces[index], elapsed())
        }
    }

    var recentTraces: [SupermuxBrowserProxyTrace] { lock.withLock { traces } }

    private func elapsed() -> Double {
        let duration = ContinuousClock.now - traceStart
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    #endif
}

#if DEBUG
/// One proxy connection's timeline in seconds since its proxy started.
struct SupermuxBrowserProxyTrace: Sendable {
    let id: Int
    let accepted: Double
    var firstByte: Double?
    var firstBytes = ""
    var decided: Double?
    var target = ""
    var ended: Double?
    var outcome = ""
    var tunnelOpened: Double?
    var firstRequestByte: Double?
    var requestBytes = 0
    var firstResponseByte: Double?
    var responseBytes = 0
}

/// Counts one relay direction's bytes into a trace, around the route's own transform.
final class SupermuxTracingTransform: SupermuxByteTransform, @unchecked Sendable {
    private let base: (any SupermuxByteTransform)?
    private let stats: SupermuxBrowserProxyStats
    private let trace: Int
    private let request: Bool

    init(_ base: (any SupermuxByteTransform)?, stats: SupermuxBrowserProxyStats, trace: Int, request: Bool) {
        self.base = base
        self.stats = stats
        self.trace = trace
        self.request = request
    }

    func transform(_ data: Data, eof: Bool) -> Data {
        let count = data.count
        let request = request
        if count > 0 {
            stats.trace(trace) { trace, now in
                if request {
                    if trace.firstRequestByte == nil { trace.firstRequestByte = now }
                    trace.requestBytes += count
                } else {
                    if trace.firstResponseByte == nil { trace.firstResponseByte = now }
                    trace.responseBytes += count
                }
            }
        }
        return base?.transform(data, eof: eof) ?? data
    }
}
#endif

/// The connections of one proxy listener still in their handshake. Any local
/// process can connect to the proxy, so past ``limit`` (far more than a
/// browser opens at once) a new connection is refused at accept, rather than
/// each unauthenticated one holding a socket and a task.
final class SupermuxBrowserProxyAdmission: @unchecked Sendable {
    static let limit = 64

    private let lock = NSLock()
    private var pending = 0

    /// Takes a slot for a new connection; false when every slot is taken.
    func admit() -> Bool {
        lock.withLock {
            guard pending < Self.limit else { return false }
            pending += 1
            return true
        }
    }

    /// Gives the slot back once the connection's handshake has decided.
    func release() {
        lock.withLock { pending -= 1 }
    }
}

/// Serves one accepted proxy connection: the handshake, then the route.
/// Runs off the main actor; only the tunnel open and the Mac's name hop to it.
struct SupermuxBrowserProxyConnection: Sendable {
    /// How long a client may take over its handshake, and over its request on
    /// the explanation page's route: one that connects and sends nothing (or
    /// half of it) is closed then instead of being held for good.
    static let clientDeadline: Duration = .seconds(10)

    let machine: SurfaceMachineID
    let credential: BrowserProxyCredential
    let stats: SupermuxBrowserProxyStats
    let admission: SupermuxBrowserProxyAdmission

    /// Serves a connection the listener admitted; its admission slot is given
    /// back once the handshake has decided.
    func serve(_ accepted: NWConnection) async {
        let local: SupermuxNWConnectionStream
        do {
            local = try await SupermuxNWConnectionStream.accepted(accepted)
        } catch {
            admission.release()
            accepted.cancel()
            return
        }
        #if DEBUG
        let trace = stats.beginTrace()
        defer { stats.trace(trace) { $0.ended = $1 } }
        #else
        let trace = 0
        #endif
        // On every exit below, clean or not: an uncancelled connection keeps its socket.
        defer { local.close() }
        let target = await handshake(local, trace: trace)
        admission.release()
        guard let target else { return }
        #if DEBUG
        stats.trace(trace) { $0.decided = $1; $0.target = "\(target.kind == .socks5 ? "socks5" : "connect") \(target.host):\(target.port)" }
        #endif
        switch SupermuxBrowserProxyDestination(host: target.host) {
        case .owner(let host, let rewritesAlias):
            await relayToOwner(local, target: target, host: host, rewritesAlias: rewritesAlias, trace: trace)
        case .direct:
            await relayDirect(local, target: target)
        }
    }

    /// Reads until the handshake decides, within ``clientDeadline``; nil when
    /// the connection was refused, ended or ran out of time (it is then aborted).
    private func handshake(_ local: SupermuxNWConnectionStream, trace: Int) async -> SupermuxBrowserProxyHandshake.Target? {
        var handshake = SupermuxBrowserProxyHandshake(credential: credential)
        #if DEBUG
        var received = 0
        #endif
        let watchdog = closeAfterDeadline(local)
        defer { watchdog.cancel() }
        do {
            while let bytes = try await local.readRaw(maximumByteCount: 16 * 1024) {
                #if DEBUG
                if received == 0 {
                    let hex = bytes.prefix(3).map { String(format: "%02x", $0) }.joined()
                    stats.trace(trace) { $0.firstByte = $1; $0.firstBytes = hex }
                }
                received += bytes.count
                #endif
                let step = handshake.consume(bytes)
                if !step.reply.isEmpty { try await local.write(step.reply) }
                switch step.decision {
                case .needMore: continue
                case .close:
                    await local.abort()
                    return nil
                case .connect(let target): return target
                }
            }
        } catch {}
        #if DEBUG
        stats.trace(trace) { trace, _ in trace.outcome = received == 0 ? "silent" : "no-handshake" }
        #endif
        await local.abort()
        return nil
    }

    /// Closes `local` unless the returned task is cancelled within
    /// ``clientDeadline``; a read waiting on the client then throws.
    private func closeAfterDeadline(_ local: SupermuxNWConnectionStream) -> Task<Void, any Error> {
        Task {
            try await Task.sleep(for: Self.clientDeadline)
            local.close()
        }
    }

    private func relayToOwner(
        _ local: SupermuxNWConnectionStream, target: SupermuxBrowserProxyHandshake.Target, host: String, rewritesAlias: Bool,
        trace: Int
    ) async {
        stats.noteOwnerDial()
        let remote: any SupermuxByteStream
        do {
            remote = try await SupermuxDeviceTunnelClient.open(machine: machine, host: host, port: target.port)
            #if DEBUG
            stats.trace(trace) { $0.tunnelOpened = $1 }
            #endif
        } catch {
            stats.noteFailure()
            if rewritesAlias {
                await explain(error, to: local, target: target)
            } else {
                try? await local.write(target.failureReply)
                await local.finish()
            }
            return
        }
        let origin = SupermuxAliasRequestOrigin()
        let aliasRequests: (any SupermuxByteTransform)? = rewritesAlias ? SupermuxAliasRequestTransform(origin: origin) : nil
        let aliasResponses: (any SupermuxByteTransform)? = rewritesAlias ? SupermuxAliasResponseTransform(origin: origin) : nil
        #if DEBUG
        let requests: (any SupermuxByteTransform)? = SupermuxTracingTransform(aliasRequests, stats: stats, trace: trace, request: true)
        let responses: (any SupermuxByteTransform)? = SupermuxTracingTransform(aliasResponses, stats: stats, trace: trace, request: false)
        #else
        let requests = aliasRequests
        let responses = aliasResponses
        #endif
        await relay(local, remote, target: target, requests: requests, responses: responses)
    }

    private func relayDirect(_ local: SupermuxNWConnectionStream, target: SupermuxBrowserProxyHandshake.Target) async {
        stats.noteDirectDial()
        let remote: SupermuxNWConnectionStream
        do {
            remote = try await SupermuxNWConnectionStream.connect(host: target.host, port: target.port)
        } catch {
            stats.noteFailure()
            try? await local.write(target.failureReply)
            await local.finish()
            return
        }
        defer { remote.close() }
        await relay(local, remote, target: target, requests: nil, responses: nil)
    }

    /// Answers the handshake, sends the bytes the client already sent, then
    /// copies both ways until both directions end.
    private func relay(
        _ local: SupermuxNWConnectionStream, _ remote: any SupermuxByteStream, target: SupermuxBrowserProxyHandshake.Target,
        requests: (any SupermuxByteTransform)?, responses: (any SupermuxByteTransform)?
    ) async {
        do {
            try await local.write(target.successReply)
            let first = requests?.transform(target.pending, eof: false) ?? target.pending
            if !first.isEmpty { try await remote.write(first) }
        } catch {
            await local.abort()
            await remote.abort()
            return
        }
        await SupermuxByteStreamPump.run(local, remote, localToRemote: requests, remoteToLocal: responses)
    }

    /// The owning Mac's `localhost` cannot be reached: accept the tunnel, read
    /// the browser's request headers, and answer with the explanation page.
    private func explain(_ error: any Error, to local: SupermuxNWConnectionStream, target: SupermuxBrowserProxyHandshake.Target) async {
        let reason = SupermuxBrowserProxyErrorPage.Reason(error)
        let machine = machine
        let name = await MainActor.run {
            SupermuxComposition.devices.device(for: machine)?.displayName
                ?? String(localized: "supermux.mirror.otherMac", defaultValue: "the other Mac")
        }
        do {
            try await local.write(target.successReply)
            try await readRequestHead(local, pending: target.pending)
            try await local.write(SupermuxBrowserProxyErrorPage.response(reason: reason, machineName: name, port: target.port))
            await local.finish()
        } catch {
            await local.abort()
        }
    }

    /// Reads the browser's request up to the end of its headers (it is not
    /// used), within ``clientDeadline``.
    private func readRequestHead(_ local: SupermuxNWConnectionStream, pending: Data) async throws {
        let watchdog = closeAfterDeadline(local)
        defer { watchdog.cancel() }
        var request = pending
        let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])
        while request.range(of: marker) == nil, request.count < 64 * 1024,
              let more = try await local.readRaw(maximumByteCount: 16 * 1024) {
            request.append(more)
        }
    }
}

/// Whether the first request on an alias connection came from a page on
/// `localhost` itself (a mirror page loaded as written, whose
/// `SupermuxMirrorLoopbackBridge` sent another port's request through the
/// alias): its `Origin` is a loopback one, so the answer's
/// `Access-Control-Allow-Origin` must stay as the server wrote it; mapped to
/// the alias it would no longer match the page and the browser would refuse
/// the response.
final class SupermuxAliasRequestOrigin: @unchecked Sendable {
    private let lock = NSLock()
    private var loopback = false

    var isLoopback: Bool { lock.withLock { loopback } }

    /// Reads the `Origin` header of a request head.
    func note(requestHead: Data) {
        let text = String(decoding: requestHead, as: UTF8.self)
        let origin = text.components(separatedBy: "\r\n").dropFirst().first { $0.lowercased().hasPrefix("origin:") }
        guard let value = origin?.dropFirst("origin:".count).trimmingCharacters(in: .whitespaces),
              let host = RemoteLoopbackProxyAlias.normalizeHost(value) else { return }
        let isLoopback = RemoteLoopbackProxyAlias.isLoopbackHost(host)
        lock.withLock { loopback = isLoopback }
    }
}

/// Browser -> owning Mac on the alias route: the first request's line, `Host`,
/// `Origin` and `Referer` go back to `localhost` (dev servers' host checks
/// pass), exactly as upstream's SSH proxy does. Its `Origin` is noted first
/// (``SupermuxAliasRequestOrigin``).
final class SupermuxAliasRequestTransform: SupermuxByteTransform, @unchecked Sendable {
    private let lock = NSLock()
    private var rewriter = RemoteLoopbackHTTPRequestStreamRewriter(aliasHost: RemoteLoopbackProxyAlias.aliasHost)
    private let origin: SupermuxAliasRequestOrigin
    private var head = Data()
    private var headNoted = false

    init(origin: SupermuxAliasRequestOrigin) {
        self.origin = origin
    }

    func transform(_ data: Data, eof: Bool) -> Data {
        lock.withLock {
            if !headNoted {
                head.append(data)
                if head.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) != nil || head.count > 64 * 1024 || eof {
                    headNoted = true
                    origin.note(requestHead: head)
                    head = Data()
                }
            }
            return rewriter.rewriteNextChunk(data, eof: eof)
        }
    }
}

/// Owning Mac -> browser on the alias route: the first response's headers
/// (redirects, cookies) name the alias again, upstream's
/// `RemoteDaemonProxySession.rewriteRemoteResponseIfNeeded`.
final class SupermuxAliasResponseTransform: SupermuxByteTransform, @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var forwardedHeaders = false
    private let origin: SupermuxAliasRequestOrigin

    init(origin: SupermuxAliasRequestOrigin) {
        self.origin = origin
    }

    func transform(_ data: Data, eof: Bool) -> Data {
        lock.withLock {
            guard !forwardedHeaders, !data.isEmpty || eof else { return data }
            pending.append(data)
            let headersComplete = pending.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) != nil
            guard headersComplete || eof else { return Data() }
            forwardedHeaders = true
            let payload = pending
            pending = Data()
            guard headersComplete else { return payload }
            let rewritten = RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(data: payload, aliasHost: RemoteLoopbackProxyAlias.aliasHost)
            return origin.isLoopback ? Self.keepingAllowOrigin(of: payload, in: rewritten) : rewritten
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
