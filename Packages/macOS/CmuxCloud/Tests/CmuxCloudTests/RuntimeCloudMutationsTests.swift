// SUPERMUX:begin runtime-cloud-mutations-channel-regressions
@testable import CmuxCloud
import CmuxCloudTui
import Foundation
import Testing

@MainActor
@Suite("Runtime Cloud mutation receipts", .timeLimit(.minutes(1)))
struct RuntimeCloudMutationsTests {
    @Test("A sent mutation keeps its real channel receipt when its caller or queue cancels",
          arguments: [false, true])
    func committedReceiptSurvives(cancelCaller: Bool) async throws {
        let server = try RuntimeCloudMutationsSocket()
        let channel = CloudTuiPersistentResourceConnection(socketPath: server.path)
        let queue = CloudTerminalMutationQueue()
        var handled: String?
        let caller = Task {
            try await queue.runCommitted {
                let bytes = try await channel.request(CloudTuiRequest("tab.create_browser", mutation: true))
                let receipt = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: String])
                handled = receipt["tab_id"]
                return handled
            }
        }
        let sent = try await server.next()
        if cancelCaller { caller.cancel() } else { queue.cancelAll() }
        try await server.reply(to: sent, result: ["tab_id": "committed-tab"])
        _ = await caller.result
        await queue.waitForIdle()
        #expect(handled == "committed-tab", "Cancellation must not discard a remotely committed receipt")

        // An ordered read proves cancellation didn't retire the create request or replay it.
        let probe = Task { try await channel.request(CloudTuiRequest("session.snapshot")) }
        var methods: [String] = []
        while true {
            let line = try await server.next()
            let object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
            let method = try #require(object["operation"] as? String)
            methods.append(method)
            try await server.reply(to: line, result: ["done": "true"])
            if method == "session.snapshot" { break }
        }
        _ = try await probe.value
        #expect(methods == ["session.snapshot"], "Committed receipt ownership must not send request.cancel or replay")
        await channel.close()
        await server.close()
    }

    @Test("A cancelled unsent queue turn never reaches the real channel")
    func unsentTurnIsCancelled() async throws {
        let server = try RuntimeCloudMutationsSocket()
        let channel = CloudTuiPersistentResourceConnection(socketPath: server.path)
        let queue = CloudTerminalMutationQueue()
        let active = queue.enqueue { try await channel.request(CloudTuiRequest("session.snapshot")) }
        let first = try await server.next()
        let entered = AsyncStream<Void>.makeStream()
        var unsentRan = false
        let caller = Task {
            entered.continuation.yield(())
            return try await queue.runCommitted {
                unsentRan = true
                return try await channel.request(CloudTuiRequest("tab.create_browser", mutation: true))
            }
        }
        for await _ in entered.stream { break }
        caller.cancel()
        try await server.reply(to: first, result: ["done": "true"])
        _ = try await active.value
        await #expect(throws: CancellationError.self) { try await caller.value }
        await queue.waitForIdle()
        #expect(!unsentRan)
        await channel.close()
        await server.close()
    }
}
// SUPERMUX:end runtime-cloud-mutations-channel-regressions
