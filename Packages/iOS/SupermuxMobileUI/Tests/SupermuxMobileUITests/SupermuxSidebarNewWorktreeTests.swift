import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// The m7 sidebar create-worktree flow on ``SupermuxProjectsSectionModel``:
/// `requestNewWorktree` fetches an authoritative branch snapshot, then
/// presents the sheet payload; failures surface visibly; the transient state
/// never survives its session; and the snapshot advertises the affordance
/// only on a `supermux.worktrees.v1` host.
@MainActor
@Suite struct SupermuxSidebarNewWorktreeTests {
    private let wait = TestWait()

    private static let projectsCapability = SupermuxMobileCapability.projectsV1.rawValue
    private static let worktreesCapability = SupermuxMobileCapability.worktreesV1.rawValue

    private func fixtureProject(
        id: String = "11111111-1111-1111-1111-111111111111",
        name: String = "Alpha"
    ) -> SupermuxProjectDTO {
        SupermuxProjectDTO(
            id: id,
            name: name,
            rootPath: "/Users/dev/alpha",
            defaultBranch: "main"
        )
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "SupermuxSidebarNewWorktreeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func runningModel(
        client: FakeSupermuxMacClient,
        capabilities: [String] = [projectsCapability, worktreesCapability]
    ) async throws -> (model: SupermuxProjectsSectionModel, session: Task<Void, Never>) {
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = Task {
            await model.runSession(client: client, hostCapabilities: Set(capabilities))
        }
        try await wait.until { model.snapshot.hasLoaded }
        return (model, session)
    }

    @Test func presentationCarriesLoadedAgentOptionsOnlyWithTheCapability() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [], branches: ["main"])
        client.agentOptionsResponse = SupermuxAgentLaunchOptionsDTO(
            commands: ["claude", "cc"], selectedCommand: "cc",
            models: [SupermuxAgentModelDTO(value: "opus", displayName: "Opus")],
            modelsSource: .cache, lastModel: "opus"
        )
        let without = try await runningModel(client: client)
        defer { without.session.cancel() }
        await without.model.requestNewWorktree(project.id)?.value
        let plain = try #require(without.model.newWorktreePresentation)
        #expect(plain.agentStore == nil)
        #expect(!client.callLog.contains("agentOptions"))
        without.model.dismissNewWorktree()

        let with = try await runningModel(
            client: client,
            capabilities: [Self.projectsCapability, Self.worktreesCapability, SupermuxMobileCapability.agentLaunchV1.rawValue]
        )
        defer { with.session.cancel() }
        await with.model.requestNewWorktree(project.id)?.value
        let presentation = try #require(with.model.newWorktreePresentation)
        let agentStore = try #require(presentation.agentStore)
        #expect(agentStore.command == "cc")
        #expect(agentStore.selectedModel == "opus")
        #expect(client.callLog.contains("agentOptions"))
    }

    @Test func requestFetchesBranchesThenPresentsTheSheetPayload() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(
            worktrees: [],
            branches: ["main", "develop"]
        )
        let (model, session) = try await runningModel(client: client)
        defer { session.cancel() }

        model.requestNewWorktree(project.id)
        try await wait.until { model.newWorktreePresentation != nil }

        let presentation = try #require(model.newWorktreePresentation)
        #expect(presentation.row.id == project.id)
        #expect(presentation.row.defaultBranch == "main")
        // The branch snapshot was fetched fresh (include_branches), so the
        // sheet's picker opens on real data.
        #expect(presentation.store.branches == ["main", "develop"])
        #expect(presentation.store.supportsStartingBranchSelection)
        #expect(model.preparingNewWorktreeProjectID == nil)

        model.dismissNewWorktree()
        #expect(model.newWorktreePresentation == nil)
    }

    @Test func anExpandedProjectsSectionStoreIsReused() async throws {
        // One mutation path: with the project's disclosure open, the sheet
        // must run through the SAME section-owned store whose event loop
        // feeds the nested rows — not a second, parallel store.
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(
            worktrees: [],
            branches: ["main"]
        )
        let (model, session) = try await runningModel(client: client)
        defer { session.cancel() }

        model.toggleProjectExpanded(project.id)
        try await wait.until { model.snapshot.rows.first?.nestedWorktrees != .unavailable }
        let sectionStore = try #require(model.worktreeSessions[project.id]?.store)

        model.requestNewWorktree(project.id)
        try await wait.until { model.newWorktreePresentation != nil }
        #expect(model.newWorktreePresentation?.store === sectionStore)
    }

    @Test func aFailedBranchFetchSurfacesVisiblyAndNeverPresents() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let (model, session) = try await runningModel(client: client)
        defer { session.cancel() }

        struct Boom: LocalizedError {
            var errorDescription: String? { "git exploded" }
        }
        client.worktreesListError = Boom()

        model.requestNewWorktree(project.id)
        try await wait.until { model.newWorktreeErrorMessage != nil }
        #expect(model.newWorktreeErrorMessage == "git exploded")
        #expect(model.newWorktreePresentation == nil)
        #expect(model.preparingNewWorktreeProjectID == nil)

        model.dismissNewWorktreeError()
        #expect(model.newWorktreeErrorMessage == nil)
    }

    @Test func theAffordanceHidesWithoutTheWorktreesCapability() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let (model, session) = try await runningModel(
            client: client,
            capabilities: [Self.projectsCapability]
        )
        defer { session.cancel() }

        #expect(model.snapshot.showsWorktreeCreation == false)
        // The request degrades to a no-op — no store can exist to serve it.
        model.requestNewWorktree(project.id)
        #expect(model.preparingNewWorktreeProjectID == nil)
        #expect(model.newWorktreePresentation == nil)
    }

    @Test func theCapabilityAdvertisesOnTheSnapshot() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let (model, session) = try await runningModel(client: client)
        defer { session.cancel() }
        #expect(model.snapshot.showsWorktreeCreation)
    }

    @Test func endSessionDropsTheTransientCreateState() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(
            worktrees: [],
            branches: ["main"]
        )
        let (model, session) = try await runningModel(client: client)
        defer { session.cancel() }

        model.requestNewWorktree(project.id)
        try await wait.until { model.newWorktreePresentation != nil }

        // Disconnect: the presented sheet's store belongs to the dead
        // connection, so the presentation must drop with it.
        model.endSession()
        #expect(model.newWorktreePresentation == nil)
        #expect(model.preparingNewWorktreeProjectID == nil)
    }

    @Test func endSessionDropsASurfacedPreparationFailure() async throws {
        // A surfaced failure alert describes the DEAD session; it must not
        // linger over the one replacing it.
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let (model, session) = try await runningModel(client: client)
        defer { session.cancel() }

        struct Boom: LocalizedError {
            var errorDescription: String? { "git exploded" }
        }
        client.worktreesListError = Boom()
        model.requestNewWorktree(project.id)
        try await wait.until { model.newWorktreeErrorMessage != nil }

        model.endSession()
        #expect(model.newWorktreeErrorMessage == nil)
    }

    @Test func aStaleFetchNeverClearsANewerRequestsSpinner() async throws {
        // A request left in flight across a session replacement must not, on
        // completion, clear the preparing marker a NEWER request for the same
        // project now owns.
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(
            worktrees: [],
            branches: ["main"]
        )
        client.worktreesListShouldHoldBranchFetches = true
        let (model, session) = try await runningModel(client: client)
        defer { session.cancel() }

        let stalePreparation = try #require(model.requestNewWorktree(project.id))
        try await wait.until { model.preparingNewWorktreeProjectID == project.id }

        // Replacement session: resets the flow and bumps the generation while
        // the first branch fetch is still parked.
        session.cancel()
        let replacement = Task {
            await model.runSession(client: client, hostCapabilities: Set([
                Self.projectsCapability, Self.worktreesCapability,
            ]))
        }
        defer { replacement.cancel() }
        try await wait.until {
            model.preparingNewWorktreeProjectID == nil
                && model.snapshot.rows.first?.id == project.id
        }

        // The newer request against the fresh session takes the marker…
        let freshPreparation = try #require(model.requestNewWorktree(project.id))
        #expect(model.preparingNewWorktreeProjectID == project.id)

        // …and the stale fetch finishing (FIFO: it parked first) must not
        // steal its spinner. Await its actual preparation task, not a timing
        // guess about when the resumed continuation reaches the generation guard.
        client.resumeWorktreesList()
        _ = await stalePreparation.value
        #expect(model.preparingNewWorktreeProjectID == project.id)
        #expect(model.newWorktreePresentation == nil)

        // Let the still-parked newer fetch finish: it presents normally.
        client.worktreesListShouldHoldBranchFetches = false
        client.resumeAllWorktreesList()
        _ = await freshPreparation.value
        #expect(model.newWorktreePresentation != nil)
        #expect(model.preparingNewWorktreeProjectID == nil)
    }
}
