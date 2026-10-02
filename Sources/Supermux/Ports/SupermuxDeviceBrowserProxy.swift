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
    /// The endpoint browsers use, once the listener is ready.
    private(set) var endpoint: BrowserProxyEndpoint?
    /// Dial counters for the E2E (``SupermuxMirrorBrowserSocket``).
    let stats = SupermuxBrowserProxyStats()

    private let credential = BrowserProxyCredential.random()
    private let onReady: @MainActor (BrowserProxyEndpoint) -> Void
    private var listener: NWListener?

    init(machine: SurfaceMachineID, onReady: @escaping @MainActor (BrowserProxyEndpoint) -> Void) {
        self.machine = machine
        self.onReady = onReady
    }

    /// Starts listening unless it already is (or is starting). A listener that
    /// failed is replaced on the next call.
    func start() {
        guard listener == nil else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return }
        self.listener = listener
        let connection = SupermuxBrowserProxyConnection(machine: machine, credential: credential, stats: stats)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                self.listenerChanged(state, port: listener.port?.rawValue)
            }
        }
        listener.newConnectionHandler = { accepted in
            Task.detached { await connection.serve(accepted) }
        }
        listener.start(queue: .main)
    }

    private func listenerChanged(_ state: NWListener.State, port: UInt16?) {
        switch state {
        case .ready:
            guard let port, port != 0 else { return }
            SupermuxOwnListenerPorts.shared.insert(Int(port))
            let endpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: Int(port), credential: credential)
            self.endpoint = endpoint
            onReady(endpoint)
        case .failed:
            if let port = endpoint?.port { SupermuxOwnListenerPorts.shared.remove(port) }
            endpoint = nil
            listener?.cancel()
            listener = nil
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
}

/// Serves one accepted proxy connection: the handshake, then the route.
/// Runs off the main actor; only the tunnel open and the Mac's name hop to it.
struct SupermuxBrowserProxyConnection: Sendable {
    let machine: SurfaceMachineID
    let credential: BrowserProxyCredential
    let stats: SupermuxBrowserProxyStats

    func serve(_ accepted: NWConnection) async {
        let local: SupermuxNWConnectionStream
        do {
            local = try await SupermuxNWConnectionStream.accepted(accepted)
        } catch {
            accepted.cancel()
            return
        }
        // On every exit below, clean or not: an uncancelled connection keeps its socket.
        defer { local.close() }
        guard let target = await handshake(local) else { return }
        switch SupermuxBrowserProxyDestination(host: target.host) {
        case .owner(let host, let rewritesAlias):
            await relayToOwner(local, target: target, host: host, rewritesAlias: rewritesAlias)
        case .direct:
            await relayDirect(local, target: target)
        }
    }

    /// Reads until the handshake decides; nil when the connection was refused or ended.
    private func handshake(_ local: SupermuxNWConnectionStream) async -> SupermuxBrowserProxyHandshake.Target? {
        var handshake = SupermuxBrowserProxyHandshake(credential: credential)
        do {
            while let bytes = try await local.readRaw(maximumByteCount: 16 * 1024) {
                let step = handshake.consume(bytes)
                if !step.reply.isEmpty { try await local.write(step.reply) }
                switch step.decision {
                case .needMore: continue
                case .close:
                    await local.finish()
                    return nil
                case .connect(let target): return target
                }
            }
        } catch {}
        await local.abort()
        return nil
    }

    private func relayToOwner(
        _ local: SupermuxNWConnectionStream, target: SupermuxBrowserProxyHandshake.Target, host: String, rewritesAlias: Bool
    ) async {
        stats.noteOwnerDial()
        let remote: any SupermuxByteStream
        do {
            remote = try await SupermuxDeviceTunnelClient.open(machine: machine, host: host, port: target.port)
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
        let requests: (any SupermuxByteTransform)? = rewritesAlias ? SupermuxAliasRequestTransform() : nil
        let responses: (any SupermuxByteTransform)? = rewritesAlias ? SupermuxAliasResponseTransform() : nil
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
            var request = target.pending
            let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])
            while request.range(of: marker) == nil, request.count < 64 * 1024,
                  let more = try await local.readRaw(maximumByteCount: 16 * 1024) {
                request.append(more)
            }
            try await local.write(SupermuxBrowserProxyErrorPage.response(reason: reason, machineName: name, port: target.port))
            await local.finish()
        } catch {
            await local.abort()
        }
    }
}

/// Browser -> owning Mac on the alias route: the first request's line, `Host`,
/// `Origin` and `Referer` go back to `localhost` (dev servers' host checks
/// pass), exactly as upstream's SSH proxy does.
final class SupermuxAliasRequestTransform: SupermuxByteTransform, @unchecked Sendable {
    private let lock = NSLock()
    private var rewriter = RemoteLoopbackHTTPRequestStreamRewriter(aliasHost: RemoteLoopbackProxyAlias.aliasHost)

    func transform(_ data: Data, eof: Bool) -> Data {
        lock.withLock { rewriter.rewriteNextChunk(data, eof: eof) }
    }
}

/// Owning Mac -> browser on the alias route: the first response's headers
/// (redirects, cookies) name the alias again, upstream's
/// `RemoteDaemonProxySession.rewriteRemoteResponseIfNeeded`.
final class SupermuxAliasResponseTransform: SupermuxByteTransform, @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var forwardedHeaders = false

    func transform(_ data: Data, eof: Bool) -> Data {
        lock.withLock {
            guard !forwardedHeaders, !data.isEmpty || eof else { return data }
            pending.append(data)
            let headersComplete = pending.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) != nil
            guard headersComplete || eof else { return Data() }
            forwardedHeaders = true
            let payload = pending
            pending = Data()
            return headersComplete
                ? RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(data: payload, aliasHost: RemoteLoopbackProxyAlias.aliasHost)
                : payload
        }
    }
}
