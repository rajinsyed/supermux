// SUPERMUX:begin runtime-cloud-mutations-theme-ownership-regressions
@testable import CmuxCloud
import CmuxCloudTui
import Foundation
import Testing

@MainActor
@Suite("Runtime Cloud autonomous theme ownership", .timeLimit(.minutes(1)))
struct RuntimeCloudMutationsThemeOwnershipTests {
    @Test("An admitted host theme cannot authorize a cancelled unsent browser", arguments: [false, true])
    func themeCannotAdmitBrowser(cancelCaller: Bool) async throws {
        let server = try RuntimeCloudMutationsSocket()
        let harness = RuntimeCloudMutationsThemeHarness()
        let channel = CloudTuiPersistentResourceConnection(socketPath: server.path) {
            await harness.beforeSend()
        }
        let manager = CloudMachineLinkManager(clientURL: nil, hostThemeColors: {
            (foreground: "#112233", background: "#445566")
        })
        let queue = CloudTerminalMutationQueue()
        let beginBrowser = CloudLinkFirstValue<Bool>()
        // A liveness deadline only; the assertions synchronize through gates and wire replies.
        let deadline = DispatchWorkItem {
            Task { @MainActor in
                #expect(Bool(false), "Theme/browser regression exceeded its liveness deadline")
                beginBrowser.resolve(false)
                harness.entered.resolve(false)
                harness.release.resolve(false)
                queue.cancelAll()
                await channel.close()
                await server.close()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(30), execute: deadline)
        defer { deadline.cancel() }
        var browserReceipt: Data?
        let caller = Task {
            try await queue.runCommitted {
                // Cold connect and connected-link refresh use this exact manager scheduler.
                await manager.scheduleHostThemePush(machineID: "machine", socketPath: server.path) { request in
                    await harness.record(ownsTurn: CloudCommittedMutationOwnership.current != nil)
                    _ = try await channel.request(request)
                    return true
                }
                _ = await beginBrowser.result
                browserReceipt = try await channel.request(CloudTuiRequest("tab.create_browser", mutation: true))
            }
        }
        let theme = try await server.next()
        let themeEnvelope = try envelope(theme)
        #expect(themeEnvelope["operation"] as? String == "session.terminal_defaults.update")
        #expect(themeEnvelope["idempotency_key"] != nil)
        #expect(await harness.ownedTurns == [false], "Autonomous host-theme work must not inherit the browser owner")
        beginBrowser.resolve(true)
        _ = await harness.entered.result
        if cancelCaller { caller.cancel() } else { queue.cancelAll() }
        await #expect(throws: CancellationError.self) { try await caller.value }
        try await server.reply(to: theme, result: ["done": "true"])
        harness.release.resolve(true)

        // The ordered probe makes the absence of create bytes observable without a delay.
        let probe = Task { try await channel.request(CloudTuiRequest("session.snapshot")) }
        let methods = try await drainThroughProbe(server)
        _ = try await probe.value
        await queue.waitForIdle()
        #expect(!methods.contains("tab.create_browser"), "Theme admission must not commit an unsent browser turn")
        #expect(browserReceipt == nil, "Cancelled unsent creation must not acquire a receipt")
        await channel.close()
        await server.close()
    }

    @Test("Initial and coalesced trailing themes have no mutation owner and use the latest colors")
    func coalescedThemesAreIndependent() async throws {
        let server = try RuntimeCloudMutationsSocket()
        let channel = CloudTuiPersistentResourceConnection(socketPath: server.path)
        let harness = RuntimeCloudMutationsThemeHarness()
        let manager = CloudMachineLinkManager(clientURL: nil, hostThemeColors: { await harness.colors })
        let queue = CloudTerminalMutationQueue()
        let firstStarted = CloudLinkFirstValue<Bool>()
        let rerunsQueued = CloudLinkFirstValue<Bool>()
        let secondFinished = CloudLinkFirstValue<Bool>()
        // Bound every socket read and continuation if a future scheduler regression stalls.
        let deadline = DispatchWorkItem {
            Task { @MainActor in
                #expect(Bool(false), "Coalesced-theme regression exceeded its liveness deadline")
                firstStarted.resolve(false)
                rerunsQueued.resolve(false)
                secondFinished.resolve(false)
                queue.cancelAll()
                await channel.close()
                await server.close()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(30), execute: deadline)
        defer { deadline.cancel() }
        let send: @Sendable (CloudTuiRequest) async throws -> Bool = { request in
            await harness.record(ownsTurn: CloudCommittedMutationOwnership.current != nil)
            _ = try await channel.request(request)
            if await harness.ownedTurns.count == 2 { secondFinished.resolve(true) }
            return true
        }
        let caller = Task {
            try await queue.runCommitted {
                await manager.scheduleHostThemePush(machineID: "machine", socketPath: server.path, send: send)
                _ = await firstStarted.result
                await harness.setColors(foreground: "#223344", background: "#556677")
                await manager.scheduleHostThemePush(machineID: "machine", socketPath: server.path, send: send)
                await harness.setColors(foreground: "#334455", background: "#667788")
                await manager.scheduleHostThemePush(machineID: "machine", socketPath: server.path, send: send)
                rerunsQueued.resolve(true)
                _ = await secondFinished.result
            }
        }
        let first = try await server.next()
        #expect(try envelope(first)["operation"] as? String == "session.terminal_defaults.update")
        firstStarted.resolve(true)
        _ = await rerunsQueued.result
        try await server.reply(to: first, result: ["done": "true"])
        let second = try await server.next()
        let secondEnvelope = try envelope(second)
        #expect(secondEnvelope["operation"] as? String == "session.terminal_defaults.update")
        let params = try #require(secondEnvelope["params"] as? [String: String])
        #expect(params["foreground"] == "#334455")
        #expect(params["background"] == "#667788")
        #expect(params["machine"] == "current")
        #expect(params["session"] == "current")
        try await server.reply(to: second, result: ["done": "true"])
        try await caller.value
        #expect(await harness.ownedTurns == [false, false])
        let probe = Task { try await channel.request(CloudTuiRequest("session.snapshot")) }
        #expect(try await drainThroughProbe(server) == ["session.snapshot"], "A reload burst must stay coalesced")
        _ = try await probe.value
        await channel.close()
        await server.close()
    }

    private func envelope(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func drainThroughProbe(_ server: RuntimeCloudMutationsSocket) async throws -> [String] {
        var methods: [String] = []
        while true {
            let line = try await server.next()
            let method = try #require(envelope(line)["operation"] as? String)
            methods.append(method)
            try await server.reply(to: line, result: ["tab_id": "unexpected-browser", "done": "true"])
            if method == "session.snapshot" { return methods }
        }
    }
}

// SUPERMUX:end runtime-cloud-mutations-theme-ownership-regressions
