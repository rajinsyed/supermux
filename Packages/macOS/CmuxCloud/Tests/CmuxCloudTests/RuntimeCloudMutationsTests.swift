// SUPERMUX:begin runtime-cloud-mutations-channel-regressions
@testable import CmuxCloud
import CmuxCloudTui
import CmuxSurfaceCatalogModel
import Foundation
import Testing

@MainActor
@Suite("Runtime Cloud mutation receipts", .timeLimit(.minutes(1)))
struct RuntimeCloudMutationsTests {
    @Test("A sent mutation keeps its receipt for adoption or compensating close",
          arguments: [false, true], [false, true])
    func committedReceiptSurvives(cancelCaller: Bool, eligible: Bool) async throws {
        let server = try RuntimeCloudMutationsSocket()
        let channel = CloudTuiPersistentResourceConnection(socketPath: server.path)
        let queue = CloudTerminalMutationQueue()
        var handled: String?
        var compensated: String?
        let caller = Task {
            try await queue.runCommitted {
                let bytes = try await channel.request(CloudTuiRequest("tab.create_browser", mutation: true))
                let receipt = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                let created = try #require(CmuxTuiSnapshotParser.createdBrowser(fromCreateResult: receipt))
                if eligible {
                    handled = created.tabID
                } else {
                    // The app's recordCommittedBrowser checks the real catalog,
                    // machine and team. This branch exercises the receipt's
                    // compensating transport after an ownership rejection.
                    _ = try await channel.request(CloudTuiRequest("tab.close", ["tab": created.tabID], mutation: true))
                    compensated = created.tabID
                }
                return created.tabID
            }
        }
        let sent = try await server.next()
        if cancelCaller { caller.cancel() } else { queue.cancelAll() }
        await #expect(throws: CancellationError.self) { try await caller.value }
        try await server.reply(to: sent, result: [
            "browser_id": "browser-1", "workspace_id": "workspace-1", "screen_id": "screen-1",
            "pane_id": "pane-1", "tab_id": "committed-tab"
        ])
        if !eligible {
            let close = try await server.next()
            let object = try #require(JSONSerialization.jsonObject(with: close) as? [String: Any])
            #expect(object["operation"] as? String == "tab.close")
            #expect((object["params"] as? [String: Any])?["tab"] as? String == "committed-tab")
            try await server.reply(to: close, result: ["done": "true"])
        }
        await queue.waitForIdle()
        #expect(handled == (eligible ? "committed-tab" : nil))
        #expect(compensated == (eligible ? nil : "committed-tab"))

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

    @Test("A receipt-owned operation still observes its cancelled caller intent", arguments: [false, true])
    func committedIntentRemainsCancelled(cancelCaller: Bool) async throws {
        let server = try RuntimeCloudMutationsSocket()
        let channel = CloudTuiPersistentResourceConnection(socketPath: server.path)
        let queue = CloudTerminalMutationQueue()
        var intentWasCancelled: Bool?
        let caller = Task {
            try await queue.runCommitted {
                _ = try await channel.request(CloudTuiRequest("tab.create_browser", mutation: true))
                intentWasCancelled = CloudTerminalMutationQueue.isCurrentTurnCancelled
            }
        }
        let sent = try await server.next()
        if cancelCaller { caller.cancel() } else { queue.cancelAll() }
        await #expect(throws: CancellationError.self) { try await caller.value }
        try await server.reply(to: sent, result: ["tab_id": "committed-tab"])
        await queue.waitForIdle()
        #expect(intentWasCancelled == true, "Receipt ownership must not revive a cancelled creation intent")
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

    @Test("Cancelling a registered pending mutation before admission never sends it", arguments: [false, true])
    func pendingBeforeSendIsCancelled(cancelCaller: Bool) async throws {
        let server = try RuntimeCloudMutationsSocket()
        let entered = CloudLinkFirstValue<Bool>()
        let release = CloudLinkFirstValue<Bool>()
        let channel = CloudTuiPersistentResourceConnection(socketPath: server.path) {
            entered.resolve(true)
            _ = await release.result
        }
        let queue = CloudTerminalMutationQueue()
        let caller = Task {
            try await queue.runCommitted {
                try await channel.request(CloudTuiRequest("tab.create_browser", mutation: true))
            }
        }
        try #require(await entered.result == true)
        if cancelCaller { caller.cancel() } else { queue.cancelAll() }
        await #expect(throws: CancellationError.self) { try await caller.value }
        release.resolve(true)
        await queue.waitForIdle()
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
        #expect(!methods.contains("tab.create_browser"))
        await channel.close()
        await server.close()
    }
}
// SUPERMUX:end runtime-cloud-mutations-channel-regressions
