import CmuxMobileRPC
import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileKit
import Testing

/// The phone's agent-launch store: options load applies the Mac's last picks,
/// command switches reload, effort is clamped to the model, and `start` sends
/// exactly the current picks.
@MainActor
struct SupermuxMobileAgentLaunchStoreTests {
    private static let capability = SupermuxMobileCapability.agentLaunchV1.rawValue

    private func makeStore(
        client: FakeSupermuxMacClient,
        capabilities: [String] = [capability]
    ) -> SupermuxMobileAgentLaunchStore {
        SupermuxMobileAgentLaunchStore(
            client: client,
            capabilities: SupermuxMobileCapabilities(hostCapabilities: capabilities),
            projectID: "11111111-1111-1111-1111-111111111111"
        )
    }

    private let opus = SupermuxAgentModelDTO(
        value: "opus", displayName: "Opus", supportsEffort: true,
        supportedEffortLevels: ["low", "medium", "high"], defaultEffortLevel: "medium"
    )
    private let sol = SupermuxAgentModelDTO(value: "gpt-5.6-sol", displayName: "Sol")

    @Test func loadAppliesOptionsAndLastPicks() async {
        let client = FakeSupermuxMacClient()
        client.agentOptionsResponse = SupermuxAgentLaunchOptionsDTO(
            commands: ["claude", "cc", "ccx"], selectedCommand: "cc",
            models: [opus, sol], modelsSource: .cache, lastModel: "opus", lastEffort: "high"
        )
        let store = makeStore(client: client)
        await store.loadOptions()
        #expect(store.hasLoadedOptions)
        #expect(store.commands == ["claude", "cc", "ccx"])
        #expect(store.command == "cc")
        #expect(store.models == [opus, sol])
        #expect(store.selectedModel == "opus")
        #expect(store.selectedEffort == "high")
        #expect(store.effortLevels == ["low", "medium", "high"])
        #expect(client.recordedWireCalls.map(\.0) == ["mobile.supermux.agent.options"])
        #expect(client.recordedWireCalls.first?.1 == ["project_id": store.projectID] as NSDictionary)
    }

    @Test func unknownLastModelFallsBackToDefaultAndKeepsEffortWhenTheDefaultRowTakesIt() async {
        let client = FakeSupermuxMacClient()
        client.agentOptionsResponse = SupermuxAgentLaunchOptionsDTO(
            commands: ["claude"], selectedCommand: "claude",
            models: [sol], modelsSource: .probe, lastModel: "opus", lastEffort: "high"
        )
        let store = makeStore(client: client)
        await store.loadOptions()
        #expect(store.selectedModel == nil)
        // Sol takes no effort, so the default row (union of levels) has none.
        #expect(store.effortLevels.isEmpty)
        #expect(store.selectedEffort == nil)

        client.agentOptionsResponse = SupermuxAgentLaunchOptionsDTO(
            commands: ["claude"], selectedCommand: "claude",
            models: [SupermuxAgentModelDTO(value: "default", displayName: "Default (recommended)", supportsEffort: true, supportedEffortLevels: ["low", "high"]), opus],
            modelsSource: .probe, lastEffort: "high"
        )
        await store.loadOptions()
        #expect(store.selectedModel == nil)
        #expect(store.defaultModelEntry?.displayName == "Default (recommended)")
        #expect(store.selectableModels == [opus])
        #expect(store.effortLevels == ["low", "high"], "the default row takes effort")
        #expect(store.selectedEffort == "high", "a remembered effort survives on the default row")
    }

    @Test func effortIsClampedToTheSelectedModel() async {
        let client = FakeSupermuxMacClient()
        client.agentOptionsResponse = SupermuxAgentLaunchOptionsDTO(
            commands: ["claude"], selectedCommand: "claude", models: [opus, sol], modelsSource: .cache
        )
        let store = makeStore(client: client)
        await store.loadOptions()
        store.selectedModel = "opus"
        store.selectedEffort = "high"
        store.selectedModel = "gpt-5.6-sol"
        #expect(store.selectedEffort == nil, "Sol takes no effort flag")
        store.selectedModel = nil
        #expect(store.effortLevels == ["low", "medium", "high"], "the default row offers the union of model levels")
    }

    @Test func selectCommandReloadsThatCommand() async {
        let client = FakeSupermuxMacClient()
        client.agentOptionsResponse = SupermuxAgentLaunchOptionsDTO(
            commands: ["claude", "ccx"], selectedCommand: "claude", models: [opus], modelsSource: .cache
        )
        let store = makeStore(client: client)
        await store.loadOptions()
        client.agentOptionsResponse = SupermuxAgentLaunchOptionsDTO(
            commands: ["claude", "ccx"], selectedCommand: "ccx", models: [sol], modelsSource: .probe, lastModel: "gpt-5.6-sol"
        )
        await store.selectCommand("ccx")
        #expect(store.command == "ccx")
        #expect(store.models == [sol])
        #expect(store.selectedModel == "gpt-5.6-sol")
        #expect(client.recordedWireCalls.last?.1 == ["project_id": store.projectID, "command": "ccx"] as NSDictionary)
        await store.selectCommand("nope")
        #expect(client.recordedWireCalls.count == 2, "an unknown command sends nothing")
    }

    @Test func unavailableCatalogSurfacesReasonAndStillAllowsStart() async throws {
        let client = FakeSupermuxMacClient()
        client.agentOptionsResponse = SupermuxAgentLaunchOptionsDTO(
            commands: ["ccx"], selectedCommand: "ccx", models: [], modelsSource: .unavailable,
            modelsError: "DroidProxy is not answering"
        )
        client.agentStartResponse = SupermuxAgentStartResponse(workspaceId: "w1", workspaceName: "Fix It", branchName: "fix-it")
        let store = makeStore(client: client)
        await store.loadOptions()
        #expect(store.modelsError == "DroidProxy is not answering")
        let result = try await store.start(prompt: "fix it", baseBranch: "  ", workspaceName: " ", branchName: "typed-branch")
        #expect(result.workspaceId == "w1")
        #expect(client.recordedWireCalls.last?.0 == "mobile.supermux.agent.start")
        #expect(client.recordedWireCalls.last?.1 == [
            "project_id": store.projectID, "prompt": "fix it", "command": "ccx", "branch_name": "typed-branch",
        ] as NSDictionary)
    }

    @Test func startSendsCurrentPicksAndRethrows() async {
        let client = FakeSupermuxMacClient()
        client.agentOptionsResponse = SupermuxAgentLaunchOptionsDTO(
            commands: ["cc"], selectedCommand: "cc", models: [opus], modelsSource: .cache
        )
        let store = makeStore(client: client)
        await store.loadOptions()
        store.selectedModel = "opus"
        store.selectedEffort = "low"
        client.agentStartError = MobileShellConnectionError.rpcError("dirty_worktree", "nope")
        await #expect(throws: (any Error).self) {
            _ = try await store.start(prompt: "Add retry", baseBranch: "main")
        }
        #expect(!store.isStarting)
        #expect(client.recordedWireCalls.last?.1 == [
            "project_id": store.projectID, "prompt": "Add retry", "command": "cc",
            "model": "opus", "effort": "low", "base_branch": "main",
        ] as NSDictionary)
    }

    @Test func inertWithoutCapability() async {
        let client = FakeSupermuxMacClient()
        let store = makeStore(client: client, capabilities: [])
        #expect(!store.showsAgentLaunch)
        await store.loadOptions()
        #expect(client.callLog.isEmpty)
        #expect(!store.hasLoadedOptions)
    }
}
