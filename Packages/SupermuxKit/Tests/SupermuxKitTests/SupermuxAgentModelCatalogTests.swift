import Foundation
import Testing
@testable import SupermuxKit
import SupermuxMobileCore

/// Per-command model catalogs: cache first, probe otherwise, one shared
/// probe per command, and a graceful `unavailable` result on failure.
@MainActor
struct SupermuxAgentModelCatalogTests {
    private func makeStore() throws -> SupermuxHarnessModelCatalogStore {
        let suite = "SupermuxAgentModelCatalogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return SupermuxHarnessModelCatalogStore(defaults: defaults)
    }

    private func catalogResponse(_ values: [String]) throws -> SupermuxHarnessInitializeCatalog {
        SupermuxHarnessInitializeCatalog(response: try SupermuxHarnessJSONObject(rawValue: [
            "models": values.map { ["value": $0, "displayName": $0.uppercased(), "supportsEffort": true,
                                    "supportedEffortLevels": ["low", "high"]] },
        ]))
    }

    @Test func storagePathIsStableAndCommandSpecific() {
        #expect(SupermuxAgentModelCatalog.storagePath(for: " cc ") == "/supermux-agent-command/cc")
        #expect(SupermuxAgentModelCatalog.storagePath(for: "claude --settings x")
                == "/supermux-agent-command/claude%20%2D%2Dsettings%20x")
        #expect(SupermuxAgentModelCatalog.storagePath(for: "cc") != SupermuxAgentModelCatalog.storagePath(for: "ccx"))
    }

    @Test func probesOnceThenServesFromCache() async throws {
        let store = try makeStore()
        let calls = ProbeCounter()
        let catalog = SupermuxAgentModelCatalog(store: store, shellPath: "/bin/zsh", environment: [:]) { plan in
            await calls.record(plan.arguments[2])
            return try self.catalogResponse(["claude-opus-5"])
        }
        let first = await catalog.models(for: "cc", workingDirectoryURL: URL(fileURLWithPath: "/tmp"))
        #expect(first.source == .probe)
        #expect(first.models.map(\.value) == ["claude-opus-5"])
        #expect(first.models.first?.displayName == "CLAUDE-OPUS-5")
        #expect(first.models.first?.supportedEffortLevels == ["low", "high"])

        let second = await catalog.models(for: "cc", workingDirectoryURL: URL(fileURLWithPath: "/tmp"))
        #expect(second.source == .cache)
        #expect(second.models == first.models)
        #expect(await calls.commands == ["cc"])

        // Another command has its own catalog.
        let other = await catalog.models(for: "ccx", workingDirectoryURL: URL(fileURLWithPath: "/tmp"))
        #expect(other.source == .probe)
        #expect(await calls.commands == ["cc", "ccx"])
    }

    @Test func forceRefreshBypassesCache() async throws {
        let store = try makeStore()
        let calls = ProbeCounter()
        let catalog = SupermuxAgentModelCatalog(store: store, shellPath: "/bin/zsh", environment: [:]) { _ in
            let count = await calls.recordAndCount("claude")
            return try self.catalogResponse(count == 1 ? ["a"] : ["b"])
        }
        _ = await catalog.models(for: "claude", workingDirectoryURL: URL(fileURLWithPath: "/tmp"))
        let refreshed = await catalog.models(for: "claude", workingDirectoryURL: URL(fileURLWithPath: "/tmp"), forceRefresh: true)
        #expect(refreshed.source == .probe)
        #expect(refreshed.models.map(\.value) == ["b"])
        #expect(catalog.cachedModels(for: "claude")?.map(\.value) == ["b"])
    }

    @Test func concurrentCallersShareOneProbe() async throws {
        let store = try makeStore()
        let calls = ProbeCounter()
        let catalog = SupermuxAgentModelCatalog(store: store, shellPath: "/bin/zsh", environment: [:]) { _ in
            await calls.record("cc")
            try await Task.sleep(for: .milliseconds(50))
            return try self.catalogResponse(["x"])
        }
        async let one = catalog.models(for: "cc", workingDirectoryURL: URL(fileURLWithPath: "/tmp"))
        async let two = catalog.models(for: "cc", workingDirectoryURL: URL(fileURLWithPath: "/tmp"))
        let results = await [one, two]
        #expect(results.allSatisfy { $0.models.map(\.value) == ["x"] })
        #expect(await calls.commands.count == 1)
    }

    @Test func probeFailureDegradesToUnavailable() async throws {
        let store = try makeStore()
        let catalog = SupermuxAgentModelCatalog(store: store, shellPath: "/bin/zsh", environment: [:]) { _ in
            throw SupermuxHarnessModelCatalogProbeError.processExited(127)
        }
        let result = await catalog.models(for: "nope", workingDirectoryURL: URL(fileURLWithPath: "/tmp"))
        #expect(result.source == .unavailable)
        #expect(result.models.isEmpty)
        #expect(result.errorDescription?.contains("127") == true)
        #expect(catalog.cachedModels(for: "nope") == nil)
    }
}

private actor ProbeCounter {
    private(set) var commands: [String] = []

    func record(_ command: String) {
        commands.append(command)
    }

    func recordAndCount(_ command: String) -> Int {
        commands.append(command)
        return commands.count
    }
}
