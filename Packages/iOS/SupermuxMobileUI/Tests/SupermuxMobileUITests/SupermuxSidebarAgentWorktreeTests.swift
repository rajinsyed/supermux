import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// The sidebar's prompt-first "Start Claude in a New Worktree" flow on
/// ``SupermuxProjectsSectionModel``: the request loads options and branches,
/// then presents; the affordance is advertised only on an
/// `agent_launch.v1` host; failures surface visibly.
@MainActor
@Suite struct SupermuxSidebarAgentWorktreeTests {
    private let wait = TestWait()

    private static let baseCapabilities = [
        SupermuxMobileCapability.projectsV1.rawValue,
        SupermuxMobileCapability.worktreesV1.rawValue,
    ]
    private static let agentCapability = SupermuxMobileCapability.agentLaunchV1.rawValue

    private func fixtureProject() -> SupermuxProjectDTO {
        SupermuxProjectDTO(
            id: "11111111-1111-1111-1111-111111111111",
            name: "Alpha",
            rootPath: "/Users/dev/alpha",
            defaultBranch: "main"
        )
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "SupermuxSidebarAgentWorktreeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func runningModel(
        client: FakeSupermuxMacClient,
        capabilities: [String]
    ) async throws -> (model: SupermuxProjectsSectionModel, session: Task<Void, Never>) {
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = Task {
            await model.runSession(client: client, hostCapabilities: Set(capabilities))
        }
        try await wait.until { model.snapshot.hasLoaded }
        return (model, session)
    }

    @Test func snapshotAdvertisesAgentLaunchOnlyWithTheCapability() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let without = try await runningModel(client: client, capabilities: Self.baseCapabilities)
        defer { without.session.cancel() }
        #expect(without.model.snapshot.showsWorktreeCreation)
        #expect(!without.model.snapshot.showsAgentLaunch)
        #expect(without.model.makeAgentLaunchStore(forProjectID: fixtureProject().id) == nil)
        #expect(without.model.requestNewAgentWorktree(fixtureProject().id) == nil)

        let with = try await runningModel(client: client, capabilities: Self.baseCapabilities + [Self.agentCapability])
        defer { with.session.cancel() }
        #expect(with.model.snapshot.showsAgentLaunch)
        #expect(with.model.makeAgentLaunchStore(forProjectID: fixtureProject().id) != nil)
    }

    @Test func requestLoadsOptionsAndBranchesThenPresents() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [], branches: ["main", "dev"])
        client.agentOptionsResponse = SupermuxAgentLaunchOptionsDTO(
            commands: ["claude", "cc"], selectedCommand: "cc",
            models: [SupermuxAgentModelDTO(value: "opus", displayName: "Opus")],
            modelsSource: .cache, lastModel: "opus"
        )
        let (model, session) = try await runningModel(client: client, capabilities: Self.baseCapabilities + [Self.agentCapability])
        defer { session.cancel() }

        let task = try #require(model.requestNewAgentWorktree(project.id))
        #expect(model.preparingAgentWorktreeProjectID == project.id)
        #expect(model.actions.preparingAgentWorktreeProjectID == project.id)
        await task.value

        let presentation = try #require(model.agentWorktreePresentation)
        #expect(presentation.row.id == project.id)
        #expect(presentation.agentStore.command == "cc")
        #expect(presentation.agentStore.selectedModel == "opus")
        #expect(presentation.worktreesStore.branches == ["main", "dev"])
        #expect(model.preparingAgentWorktreeProjectID == nil)
        #expect(client.recordedWireCalls.contains { $0.0 == "mobile.supermux.agent.options" })
        #expect(client.recordedWireCalls.contains {
            $0.0 == "mobile.supermux.worktrees.list" && ($0.1["include_branches"] as? Bool) == true
        })

        model.dismissNewAgentWorktree()
        #expect(model.agentWorktreePresentation == nil)
    }

    @Test func optionsFailureSurfacesVisiblyAndNeverPresents() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.agentOptionsError = SupermuxMacUnavailableError()
        let (model, session) = try await runningModel(client: client, capabilities: Self.baseCapabilities + [Self.agentCapability])
        defer { session.cancel() }

        await model.requestNewAgentWorktree(project.id)?.value

        #expect(model.agentWorktreePresentation == nil)
        #expect(model.newWorktreeErrorMessage != nil)
        #expect(model.preparingAgentWorktreeProjectID == nil)
    }
}
