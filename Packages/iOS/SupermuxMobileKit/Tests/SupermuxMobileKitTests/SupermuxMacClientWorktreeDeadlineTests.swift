import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import SupermuxMobileKit
import Testing

/// Failure modes: creation inherits the phone's 30 s default; agent launch
/// keeps its old 90 s override; either reports failure while the host creates
/// a workspace. Exercise the production adapter and RPC deadline, with a host
/// reply delayed past each old limit. No app, network, or real worktree is used.
struct SupermuxMacClientWorktreeDeadlineTests {
    @Test(arguments: [false, true])
    func slowWorktreeReplyReachesThePhone(agent: Bool) async throws {
        let transport = SlowHost(delay: .seconds(agent ? 91 : 31))
        let route = try CmxAttachRoute(
            id: "test", kind: .debugLoopback, endpoint: .hostPort(host: "127.0.0.1", port: 59123)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace", terminalID: "terminal", macDeviceID: "mac",
            macDisplayName: "Mac", routes: [route], expiresAt: Date().addingTimeInterval(3600)
        )
        let rpc = MobileCoreRPCClient(
            runtime: Runtime(transportFactory: Factory(transport: transport)),
            route: route, ticket: ticket, allowsStackAuthFallback: true
        )
        let phone = SupermuxMacClient(client: rpc)
        do {
            let workspaceID: String?
            if agent {
                workspaceID = try await phone.agentStart(.init(projectID: "project", prompt: "Fix it")).workspaceId
            } else {
                workspaceID = try await phone.worktreeCreate(.init(
                    projectID: "project", workspaceName: nil, branchName: "feature", open: true
                )).workspaceId
            }
            #expect(workspaceID == "created-workspace")
            #expect(await transport.requestCount == 1)
            await rpc.disconnect()
        } catch {
            await rpc.disconnect()
            throw error
        }
    }

    private struct Runtime: MobileSyncRuntime {
        let transportFactory: any CmxByteTransportFactory
        let stackAccessTokenProvider: @Sendable () async throws -> String = { "test-token" }
        let stackAccessTokenForceRefresher: @Sendable () async throws -> String = { "test-token" }
        let rpcRequestTimeoutNanoseconds: UInt64 = 30_000_000_000
        let pairingRequestTimeoutNanoseconds: UInt64 = 30_000_000_000
        let now: @Sendable () -> Date = { Date() }
        let supportedRouteKinds: [CmxAttachTransportKind] = [.debugLoopback]
        let supportsServerPushEvents = false
    }

    private struct Factory: CmxByteTransportFactory {
        let transport: SlowHost
        func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport { transport }
    }

    private actor SlowHost: CmxByteTransport {
        let delay: Duration
        private var receiver: CheckedContinuation<Data?, Never>?
        private var queued: Data?
        private var responseTask: Task<Void, Never>?
        private var closed = false
        private(set) var requestCount = 0

        init(delay: Duration) { self.delay = delay }
        func connect() async throws {}

        func send(_ data: Data) async throws {
            var buffer = data
            let payload = try #require(MobileSyncFrameCodec.decodeFrames(from: &buffer).first)
            let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let id = try #require(request["id"] as? String)
            let reply = try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: [
                "id": id, "ok": true, "result": ["workspace_id": "created-workspace"],
            ]))
            requestCount += 1
            responseTask = Task {
                // Deliberate host latency to cross the reply deadline, not a settling wait.
                do { try await Task.sleep(for: delay) } catch { return }
                deliver(reply)
            }
        }

        private func deliver(_ reply: Data) {
            if let receiver {
                self.receiver = nil
                receiver.resume(returning: reply)
            } else {
                queued = reply
            }
        }

        func receive() async throws -> Data? {
            if let queued {
                self.queued = nil
                return queued
            }
            if closed { return nil }
            return await withCheckedContinuation { receiver = $0 }
        }

        func close() async {
            closed = true
            responseTask?.cancel()
            responseTask = nil
            receiver?.resume(returning: nil)
            receiver = nil
        }
    }
}
