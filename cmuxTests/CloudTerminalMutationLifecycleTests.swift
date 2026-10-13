import CmuxCloud
import CmuxCloudTui
// SUPERMUX:begin runtime-cloud-mutations-provider-test-imports
import CmuxSurfaceCatalogModel
import Darwin
// SUPERMUX:end runtime-cloud-mutations-provider-test-imports
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud terminal mutation lifecycle", .timeLimit(.minutes(1)))
struct CloudTerminalMutationLifecycleTests {
    @Test("Cancelling all turns keeps their predecessor chain until active work drains")
    func cancellationDoesNotReleaseSuccessorsEarly() async throws {
        let queue = CloudTerminalMutationQueue()
        let transport = CloudTerminalMutationTestTransport()
        var predecessorReturned = false
        var cancelledTurnRan = false
        let active = queue.enqueue {
            let data = try await transport.runTuiCommand(arguments: CloudTuiRequest("workspace.run"), deadline: .seconds(30))
            predecessorReturned = true
            return data
        }
        let cancelledTurn = queue.enqueue {
            cancelledTurnRan = true
            return Data()
        }
        defer { queue.cancelAll(); transport.release() }
        try #require(await transport.started.result == true)
        queue.cancelAll()
        #expect(active.isCancelled && cancelledTurn.isCancelled)
        let replacementTurn = queue.enqueue {
            #expect(predecessorReturned, "A fresh turn must remain behind the cancelled active transport")
            return Data("new".utf8)
        }
        transport.release(Data("late old reply".utf8))
        await #expect(throws: CancellationError.self) { try await active.value }
        await #expect(throws: CancellationError.self) { try await cancelledTurn.value }
        #expect(try await replacementTurn.value == Data("new".utf8))
        await queue.waitForIdle()
        #expect(!cancelledTurnRan)
    }

    // SUPERMUX:begin runtime-cloud-mutations-caller-waiter-test
    @Test("A committed turn retires its caller while completing its ordered work")
    func committedTurnSurvivesCancellation() async throws {
        let queue = CloudTerminalMutationQueue()
        let server = try RuntimeCloudMutationsAppSocket()
        let channel = CloudTuiPersistentResourceConnection(socketPath: server.path)
        var receipt: Data?
        let task = Task {
            try await queue.runCommitted {
                receipt = try await channel.request(CloudTuiRequest("tab.create_browser", mutation: true))
            }
        }
        let sent = try await server.next()
        queue.cancelAll()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await server.reply(to: sent, result: ["tab_id": "committed"])
        await queue.waitForIdle()
        #expect(receipt != nil)
        await channel.close()
        await server.close()
    }
    // SUPERMUX:end runtime-cloud-mutations-caller-waiter-test

    // SUPERMUX:begin runtime-cloud-mutations-provider-receipt-regressions
    @Test("A real channel receipt is adopted only by an eligible replacement or compensated",
          arguments: [false, true], ["current", "replacement", "foreign-team", "different-machine", "suspended", "resumed"])
    func browserReceiptOwnershipUsesActualProvider(cancelCaller: Bool, outcome: String) async throws {
        let server = try RuntimeCloudMutationsAppSocket()
        let channel = CloudTuiPersistentResourceConnection(socketPath: server.path)
        let catalog = SurfaceCatalog()
        let summary = machine("receipt-\(UUID())")
        let links = CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil })
        let original = CmuxTuiSurfaceProvider(summary: summary, ownerTeamID: "team", links: links, catalog: catalog)
        catalog.register(original)
        var replacement: CmuxTuiSurfaceProvider?
        defer {
            original.suspendForFeatureFlag()
            replacement?.suspendForFeatureFlag()
            if let replacement { catalog.unregister(machine: replacement.machine) }
            catalog.unregister(machine: original.machine)
        }
        let lifecycle = original.lifecycleGeneration
        var adopted: SurfaceResource?
        var compensated = false
        let caller = Task {
            try await original.terminalMutationQueue.runCommitted {
                let data = try await channel.request(CloudTuiRequests.createBrowserArguments(
                    socketPath: server.path, workspaceID: "workspace", screenID: nil, paneID: nil,
                    url: "http://localhost:4312", name: nil, idempotencyKey: "receipt-intent", correlationKey: nil
                ))
                let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let receipt = try #require(CmuxTuiSnapshotParser.createdBrowser(fromCreateResult: object))
                adopted = try await original.completeCommittedBrowserCreation(
                    receipt, url: URL(string: "http://localhost:4312")!, name: nil, expectedLifecycle: lifecycle
                ) {
                    _ = try? await channel.request(CloudTuiRequests.closeTabArguments(
                        socketPath: server.path, tabID: receipt.tabID
                    ))
                    compensated = true
                }
            }
        }
        let sent = try await server.next()
        if outcome != "current" { original.suspendForFeatureFlag() }
        if ["replacement", "foreign-team", "different-machine"].contains(outcome) {
            let next = CmuxTuiSurfaceProvider(
                summary: outcome == "different-machine" ? machine("other-\(UUID())") : summary,
                ownerTeamID: outcome == "foreign-team" ? "other-team" : "team", links: links, catalog: catalog
            )
            replacement = next
            catalog.register(next)
        } else if outcome == "resumed" {
            original.update(summary: summary)
        }
        if cancelCaller { caller.cancel() } else { original.terminalMutationQueue.cancelAll() }
        await #expect(throws: CancellationError.self) { try await caller.value }
        try await server.reply(to: sent, result: [
            "browser_id": "browser", "workspace_id": "workspace", "screen_id": "screen",
            "pane_id": "pane", "tab_id": "committed-tab"
        ])
        if outcome != "replacement" {
            let close = try await server.next()
            let object = try #require(JSONSerialization.jsonObject(with: close) as? [String: Any])
            #expect(object["operation"] as? String == "tab.close")
            #expect((object["params"] as? [String: Any])?["tab"] as? String == "committed-tab")
            try await server.reply(to: close, result: ["done": "true"])
        }
        await original.terminalMutationQueue.waitForIdle()
        #expect(compensated == (outcome != "replacement"))
        #expect(original.pendingRemoteCreations.isEmpty)
        if outcome == "replacement" {
            let resource = try #require(adopted)
            #expect(replacement?.pendingRemoteCreations[resource.id]?.tabID == "committed-tab")
            #expect(catalog.resources[resource.id]?.remoteViews?.first?.tabID == "committed-tab")
        } else {
            #expect(adopted == nil)
            #expect(replacement?.pendingRemoteCreations.isEmpty ?? true)
            #expect(catalog.resources.isEmpty)
        }
        await channel.close()
        await server.close()
    }
    // SUPERMUX:end runtime-cloud-mutations-provider-receipt-regressions

    @Test("Provider retirement rejects late command results and subsequent mutations",
          arguments: ["suspend", "replace", "unregister"], ["session.snapshot", "workspace.run", "session.creation.resolve"])
    func commandAwaitIsFenced(change: String, operation: String) async throws {
        let catalog = SurfaceCatalog()
        let provider = makeProvider(catalog: catalog)
        let transport = CloudTerminalMutationTestTransport()
        let lifecycle = provider.lifecycleGeneration
        let commands = CloudTerminalMutationCommandRunner(base: transport) {
            try provider.validateTerminalMutationLifecycle(lifecycle)
        }
        var published = false
        let task = provider.terminalMutationQueue.enqueue {
            _ = try await commands.runTuiCommand(arguments: CloudTuiRequest(operation), deadline: .seconds(30))
            _ = try await commands.runTuiCommand(arguments: CloudTuiRequest("pane.split"), deadline: .seconds(30))
            published = true
        }
        var replacement: CmuxTuiSurfaceProvider?
        defer {
            provider.suspendForFeatureFlag()
            replacement?.suspendForFeatureFlag()
            catalog.unregister(machine: provider.machine)
            transport.release()
        }
        try #require(await transport.started.result == true)
        switch change {
        case "suspend": provider.suspendForFeatureFlag()
        case "replace": replacement = makeProvider(catalog: catalog, machineID: provider.machineID)
        case "unregister": catalog.unregister(machine: provider.machine)
        default: Issue.record("Unknown lifecycle transition")
        }
        transport.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(transport.commands == [operation])
        #expect(!published)
        #expect(provider.pendingRemoteCreations.isEmpty)
        #expect(catalog.resources.isEmpty)
    }

    @Test("Suspended and replaced providers reject both creation entrypoints before connecting",
          arguments: ["suspend", "replace", "unregister"])
    func staleProviderNeverConnects(change: String) async {
        let catalog = SurfaceCatalog()
        let provider = makeProvider(catalog: catalog)
        var replacement: CmuxTuiSurfaceProvider?
        switch change {
        case "suspend": provider.suspendForFeatureFlag()
        case "replace": replacement = makeProvider(catalog: catalog, machineID: provider.machineID)
        case "unregister": catalog.unregister(machine: provider.machine)
        default: Issue.record("Unknown lifecycle transition")
        }
        defer {
            provider.suspendForFeatureFlag()
            replacement?.suspendForFeatureFlag()
            catalog.unregister(machine: provider.machine)
        }
        // The fixture has no client or hub. Reaching connection would throw a
        // transport error instead of this lifecycle cancellation.
        await #expect(throws: CancellationError.self) {
            try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: "workspace")
        }
        await #expect(throws: CancellationError.self) {
            try await provider.createTerminal(nearTabID: "tab", splitDirection: .right)
        }
    }

    @Test("A queued provider create cannot enter a replaced lifecycle",
          arguments: [false, true], ["resume", "replace"])
    func queuedCreationKeepsItsAdmittedLifecycle(layout: Bool, change: String) async throws {
        let catalog = SurfaceCatalog()
        let provider = makeProvider(catalog: catalog)
        let transport = CloudTerminalMutationTestTransport()
        let blockingTurn = provider.terminalMutationQueue.enqueue {
            try await transport.runTuiCommand(arguments: CloudTuiRequest("workspace.run"), deadline: .seconds(30))
        }
        var replacement: CmuxTuiSurfaceProvider?
        defer {
            provider.suspendForFeatureFlag()
            replacement?.suspendForFeatureFlag()
            catalog.unregister(machine: provider.machine)
            transport.release()
        }
        try #require(await transport.started.result == true)
        let admitted = CloudLinkFirstValue<Bool>()
        let request = Task {
            admitted.resolve(true)
            if layout { return try await provider.createTerminal(nearTabID: "tab", splitDirection: .right) }
            return try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: "workspace")
        }
        try #require(await admitted.result == true)
        if change == "resume" {
            provider.suspendForFeatureFlag()
            provider.update(summary: try #require(provider.summary.cloudSummary))
        } else {
            replacement = makeProvider(catalog: catalog, machineID: provider.machineID)
        }
        transport.release()
        _ = try? await blockingTurn.value
        await #expect(throws: CancellationError.self) { try await request.value }
    }

    @Test("Resume creates a new generation without reviving old queued turns")
    func suspensionInvalidatesQueuedWorkAcrossResume() async throws {
        let catalog = SurfaceCatalog()
        let provider = makeProvider(catalog: catalog)
        let transport = CloudTerminalMutationTestTransport()
        let oldGeneration = provider.lifecycleGeneration
        var queuedRan = false
        let active = provider.terminalMutationQueue.enqueue {
            try await transport.runTuiCommand(arguments: CloudTuiRequest("workspace.run"), deadline: .seconds(30))
        }
        let queued = provider.terminalMutationQueue.enqueue { queuedRan = true }
        defer {
            provider.suspendForFeatureFlag()
            catalog.unregister(machine: provider.machine)
            transport.release()
        }
        try #require(await transport.started.result == true)
        provider.suspendForFeatureFlag()
        #expect(active.isCancelled && queued.isCancelled)
        provider.update(summary: try #require(provider.summary.cloudSummary))
        #expect(throws: CancellationError.self) { try provider.validateTerminalMutationLifecycle(oldGeneration) }
        let generation = provider.lifecycleGeneration
        let next = provider.terminalMutationQueue.enqueue {
            try provider.validateTerminalMutationLifecycle(generation)
        }
        transport.release()
        await #expect(throws: CancellationError.self) { try await active.value }
        await #expect(throws: CancellationError.self) { try await queued.value }
        try await next.value
        #expect(!queuedRan)
        await provider.stop()
    }

    @Test("Account teardown quiesces every provider before awaiting the first active turn")
    func registryQuiescesAllProvidersBeforeJoining() async throws {
        let catalog = SurfaceCatalog()
        let summaries = (0..<3).map { machine("lifecycle-\(UUID())-\($0)") }
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            allowsBackgroundWork: { false },
            listPage: { VMListPage(vms: summaries, limits: nil) },
            refreshProvider: { _, _ in true },
            closeTransports: {},
            notificationCenter: NotificationCenter()
        )
        registry.start(catalog: catalog)
        _ = await registry.refresh(force: true)
        let providers = try summaries.map { try #require(registry.provider(machineID: $0.id)) }
        let cancellation = CloudLinkFirstValue<Bool>()
        let transports = providers.map { _ in CloudTerminalMutationTestTransport(cancelled: cancellation) }
        let active = zip(providers, transports).map { provider, transport in
            provider.terminalMutationQueue.enqueue {
                try await transport.runTuiCommand(arguments: CloudTuiRequest("workspace.run"), deadline: .seconds(30))
            }
        }
        defer { for transport in transports { transport.release() } }
        for transport in transports { try #require(await transport.started.result == true) }
        var finished = false
        let stop = Task { await registry.accessDidEnd(); finished = true }
        try #require(await cancellation.result == true)
        #expect(providers.allSatisfy { $0.isFeatureSuspended })
        #expect(active.allSatisfy { $0.isCancelled })
        #expect(providers.allSatisfy { catalog.provider(for: $0.machine) == nil })
        #expect(!finished, "Teardown must join the already-issued command")
        let resuming = CloudLinkFirstValue<Bool>()
        var resumed = false
        let signIn = Task {
            resuming.resolve(true)
            await registry.resumeAfterSignIn()
            resumed = true
        }
        try #require(await resuming.result == true)
        #expect(!resumed)
        #expect(await registry.providerRefreshingIfMissing(machineID: summaries[0].id) == nil)
        for transport in transports { transport.release() }
        for task in active { await #expect(throws: CancellationError.self) { try await task.value } }
        await stop.value
        #expect(finished)
        await signIn.value
        #expect(resumed)
        await registry.accessDidEnd()
    }

    @Test("Machine deletion cancels terminal turns before scheduling asynchronous cleanup")
    func deletionQuiescesProviderSynchronously() async throws {
        let catalog = SurfaceCatalog()
        let summary = machine("delete-\(UUID())")
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            allowsBackgroundWork: { false },
            listPage: { VMListPage(vms: [summary], limits: nil) },
            refreshProvider: { _, _ in true }, closeTransports: {}, notificationCenter: NotificationCenter()
        )
        registry.start(catalog: catalog)
        _ = await registry.refresh(force: true)
        let provider = try #require(registry.provider(machineID: summary.id))
        var ran = false
        let queued = provider.terminalMutationQueue.enqueue { ran = true }
        registry.machineWasDeleted(summary.id)
        #expect(provider.isFeatureSuspended)
        #expect(queued.isCancelled)
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(!ran)
        await registry.accessDidEnd()
    }

    private func makeProvider(catalog: SurfaceCatalog, machineID: String = "mutation-\(UUID())") -> CmuxTuiSurfaceProvider {
        let provider = CmuxTuiSurfaceProvider(
            summary: machine(machineID),
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            catalog: catalog
        )
        catalog.register(provider)
        return provider
    }

    private func machine(_ id: String) -> VMSummary {
        VMSummary(id: id, provider: "freestyle", status: "running", image: "fixture", createdAt: 0, base: nil)
    }
}

// SUPERMUX:begin runtime-cloud-mutations-provider-socket-fixture
/// A real socket peer for the app-owned receipt completion path.
private actor RuntimeCloudMutationsAppSocket {
    nonisolated let path: String
    private let listener: Int32
    private let accepted: Task<Int32, Error>
    private var peer: Int32?

    init() throws {
        path = NSTemporaryDirectory() + "cm-\(UUID().uuidString.prefix(12)).sock"
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        let descriptor = listener
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        address.sun_len = UInt8(2 + bytes.count)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(2 + bytes.count))
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else {
            let error = NSError(domain: "fixture.bind", code: Int(errno))
            Darwin.close(listener)
            throw error
        }
        accepted = Task {
            try await Self.performBlockingIO {
                let result = Darwin.accept(descriptor, nil, nil)
                guard result >= 0 else { throw NSError(domain: "fixture.accept", code: Int(errno)) }
                var noSignal: Int32 = 1
                setsockopt(result, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                return result
            }
        }
    }

    func next() async throws -> Data {
        let descriptor = try await accepted.value
        peer = descriptor
        return try await Self.performBlockingIO {
            var result = Data()
            var byte: UInt8 = 0
            while true {
                let count = Darwin.read(descriptor, &byte, 1)
                if count < 0, errno == EINTR { continue }
                guard count == 1 else {
                    throw NSError(domain: "fixture.read", code: count == 0 ? -1 : Int(errno))
                }
                if byte == 0x0A { return result }
                result.append(byte)
            }
        }
    }

    func reply(to request: Data, result: [String: String]) async throws {
        let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let id = try #require(object["id"] as? String)
        let response = try JSONSerialization.data(withJSONObject: [
            "id": id, "protocol": "cmux.protocol/2", "type": "response", "ok": true, "result": result
        ]) + Data([0x0A])
        let descriptor = try await accepted.value
        peer = descriptor
        try await Self.performBlockingIO {
            try response.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw NSError(domain: "fixture.write", code: Int(errno)) }
                    offset += written
                }
            }
        }
    }

    func close() {
        if let peer { Darwin.shutdown(peer, SHUT_RDWR); Darwin.close(peer); self.peer = nil }
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(path)
    }

    private static func performBlockingIO<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            // POSIX calls must not block Swift's cooperative executor.
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
// SUPERMUX:end runtime-cloud-mutations-provider-socket-fixture
