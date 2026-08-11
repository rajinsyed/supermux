import CmuxMobileRPC
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// The sidebar's swipe-to-remove on nested worktree rows.
///
/// Before the redesign the sidebar showed worktrees it gave you no way to act
/// on, while the project detail screen showed the SAME worktrees with a
/// swipe-to-remove — the same object behaving differently depending on which
/// screen you reached it from, which the repo's shared-behavior policy exists
/// to prevent.
///
/// These pin that the sidebar drives the SAME store state machine (never a
/// parallel removal path) and preserves the full UI-03 contract: nothing is
/// deleted without an explicit confirm, a dirty worktree parks in confirm-force
/// instead of failing silently, and terminal failures surface.
@MainActor
@Suite struct SupermuxSidebarWorktreeRemovalTests {
    private let wait = TestWait()

    private static let projectsCapability = SupermuxMobileCapability.projectsV1.rawValue
    private static let worktreesCapability = SupermuxMobileCapability.worktreesV1.rawValue

    private func fixtureProject(
        id: String = "11111111-1111-1111-1111-111111111111"
    ) -> SupermuxProjectDTO {
        SupermuxProjectDTO(id: id, name: "Alpha", rootPath: "/Users/dev/alpha")
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "SupermuxSidebarWorktreeRemovalTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private var looseWorktree: SupermuxWorktreeDTO {
        SupermuxWorktreeDTO(path: "/w/loose", branch: "loose", isOpen: false)
    }

    private var looseRow: SupermuxWorktreeRowSnapshot {
        SupermuxWorktreeRowSnapshot(worktree: looseWorktree)
    }

    /// Boots a model with one expanded project whose nested worktrees have
    /// loaded — the state a sidebar swipe acts from.
    private func expandedModel(
        client: FakeSupermuxMacClient,
        project: SupermuxProjectDTO
    ) async throws -> (model: SupermuxProjectsSectionModel, session: Task<Void, Never>) {
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [looseWorktree])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.worktreesCapability]
            )
        }
        try await wait.until { model.snapshot.hasLoaded }
        model.toggleProjectExpanded(project.id)
        try await wait.until {
            if case .loaded(let rows) = model.snapshot.rows.first?.nestedWorktrees {
                return rows.count == 1
            }
            return false
        }
        return (model, session)
    }

    @Test func aSwipeOnlyRaisesTheConfirmationAndNeverDeletesOnItsOwn() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        let (model, session) = try await expandedModel(client: client, project: project)
        defer { session.cancel() }

        model.actions.requestNestedWorktreeRemoval(project.id, looseRow)
        #expect(model.pendingWorktreeRemoval?.path == "/w/loose")
        #expect(model.pendingWorktreeRemoval?.displayName == "loose")
        // The critical assertion: swiping is not deleting.
        #expect(!client.callLog.contains("worktreeRemove"))

        // Dismissing drops it without touching the Mac.
        model.dismissPendingWorktreeRemoval()
        #expect(model.pendingWorktreeRemoval == nil)
        for _ in 0..<10 { await Task.yield() }
        #expect(!client.callLog.contains("worktreeRemove"))
    }

    @Test func confirmingRemovesThroughTheProjectsOwnStore() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        let (model, session) = try await expandedModel(client: client, project: project)
        defer { session.cancel() }

        model.actions.requestNestedWorktreeRemoval(project.id, looseRow)
        model.confirmPendingWorktreeRemoval()
        try await wait.until { client.callLog.contains("worktreeRemove") }
        #expect(model.pendingWorktreeRemoval == nil)

        // Same store as the detail screen: its removal state settles back to
        // idle, and the list refetches.
        try await wait.until { model.worktreeSessions[project.id]?.store.removal == .idle }
    }

    @Test func aDirtyWorktreeParksInConfirmForceRatherThanFailing() async throws {
        // UI-03's central contract: `dirty_worktree` must never read as a
        // silent no-op — it becomes a visible "remove anyway?" prompt.
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        let (model, session) = try await expandedModel(client: client, project: project)
        defer { session.cancel() }

        client.worktreeRemoveError = MobileShellConnectionError.rpcError(
            SupermuxWireErrorCode.dirtyWorktree,
            "worktree has uncommitted changes"
        )
        model.actions.requestNestedWorktreeRemoval(project.id, looseRow)
        model.confirmPendingWorktreeRemoval()

        try await wait.until { model.forcedWorktreeRemovalPrompt != nil }
        let prompt = try #require(model.forcedWorktreeRemovalPrompt)
        #expect(prompt.projectID == project.id)
        #expect(model.failedWorktreeRemovalPrompt == nil, "a dirty worktree is not a failure")

        // Confirming the force retries WITH force, and this time succeeds.
        client.worktreeRemoveError = nil
        let removeCallsBefore = client.callLog.filter { $0 == "worktreeRemove" }.count
        model.confirmForcedWorktreeRemoval(projectID: project.id)
        try await wait.until {
            client.callLog.filter { $0 == "worktreeRemove" }.count > removeCallsBefore
        }
        try await wait.until { model.forcedWorktreeRemovalPrompt == nil }
    }

    @Test func decliningTheForcePromptLeavesTheWorktreeAlone() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        let (model, session) = try await expandedModel(client: client, project: project)
        defer { session.cancel() }

        client.worktreeRemoveError = MobileShellConnectionError.rpcError(
            SupermuxWireErrorCode.dirtyWorktree,
            "worktree has uncommitted changes"
        )
        model.actions.requestNestedWorktreeRemoval(project.id, looseRow)
        model.confirmPendingWorktreeRemoval()
        try await wait.until { model.forcedWorktreeRemovalPrompt != nil }

        let removeCallsBefore = client.callLog.filter { $0 == "worktreeRemove" }.count
        model.dismissWorktreeRemovalState(projectID: project.id)
        #expect(model.forcedWorktreeRemovalPrompt == nil)
        for _ in 0..<10 { await Task.yield() }
        #expect(client.callLog.filter { $0 == "worktreeRemove" }.count == removeCallsBefore)
    }

    @Test func aTerminalFailureSurfacesAndClears() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        let (model, session) = try await expandedModel(client: client, project: project)
        defer { session.cancel() }

        client.worktreeRemoveError = MobileShellConnectionError.rpcError(
            "internal_error",
            "git worktree remove failed"
        )
        model.actions.requestNestedWorktreeRemoval(project.id, looseRow)
        model.confirmPendingWorktreeRemoval()

        try await wait.until { model.failedWorktreeRemovalPrompt != nil }
        #expect(model.forcedWorktreeRemovalPrompt == nil)

        model.dismissWorktreeRemovalState(projectID: project.id)
        #expect(model.failedWorktreeRemovalPrompt == nil)
    }

    @Test func aPendingConfirmationDoesNotSurviveAReconnect() async throws {
        // The dangerous case: a confirm raised against connection A, answered
        // after a reconnect. Its store is gone, and re-resolving the same
        // (projectID, path) against the NEW session could delete a different
        // checkout that now sits at that path — the first confirm has no
        // branch-identity recheck (only the forced retry does).
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        let (model, session) = try await expandedModel(client: client, project: project)
        defer { session.cancel() }

        model.actions.requestNestedWorktreeRemoval(project.id, looseRow)
        #expect(model.pendingWorktreeRemoval != nil)

        // A reconnect replaces the session wholesale.
        let client2 = FakeSupermuxMacClient()
        client2.listResponse = SupermuxProjectsListResponse(projects: [project])
        client2.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [looseWorktree])
        let session2 = Task {
            await model.runSession(
                client: client2,
                hostCapabilities: [Self.projectsCapability, Self.worktreesCapability]
            )
        }
        defer { session2.cancel() }
        try await wait.until { model.pendingWorktreeRemoval == nil }

        // A stray confirm now has nothing to act on, and never reaches a Mac.
        model.confirmPendingWorktreeRemoval()
        for _ in 0..<10 { await Task.yield() }
        #expect(!client.callLog.contains("worktreeRemove"))
        #expect(!client2.callLog.contains("worktreeRemove"))
    }

    @Test func endingTheSessionAlsoDropsAPendingConfirmation() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        let (model, session) = try await expandedModel(client: client, project: project)
        defer { session.cancel() }

        model.actions.requestNestedWorktreeRemoval(project.id, looseRow)
        model.endSession()
        #expect(model.pendingWorktreeRemoval == nil)

        model.confirmPendingWorktreeRemoval()
        for _ in 0..<10 { await Task.yield() }
        #expect(!client.callLog.contains("worktreeRemove"))
    }

    @Test func theForcePromptNamesTheWorktreeTheUserActuallySwiped() async throws {
        // With two projects parked in confirm-force at once, the single dialog
        // used to speak for whichever project won an UNORDERED dictionary
        // scan — so confirming could force-delete a worktree the user never
        // swiped. The prompt must follow the most recent request and name it.
        let alpha = fixtureProject(id: "11111111-1111-1111-1111-111111111111")
        let beta = SupermuxProjectDTO(
            id: "22222222-2222-2222-2222-222222222222",
            name: "Beta",
            rootPath: "/Users/dev/beta"
        )
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [alpha, beta])
        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [
            looseWorktree,
            SupermuxWorktreeDTO(path: "/w/beta", branch: "beta-branch", isOpen: false),
        ])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.worktreesCapability]
            )
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }
        model.toggleProjectExpanded(alpha.id)
        model.toggleProjectExpanded(beta.id)
        try await wait.until {
            model.worktreeSessions[alpha.id]?.store.hasLoaded == true
                && model.worktreeSessions[beta.id]?.store.hasLoaded == true
        }

        client.worktreeRemoveError = MobileShellConnectionError.rpcError(
            SupermuxWireErrorCode.dirtyWorktree,
            "worktree has uncommitted changes"
        )

        // Park BOTH projects in confirm-force, alpha first, then beta.
        model.actions.requestNestedWorktreeRemoval(alpha.id, looseRow)
        model.confirmPendingWorktreeRemoval()
        try await wait.until { model.forcedWorktreeRemovalPrompt != nil }

        let betaRow = SupermuxWorktreeRowSnapshot(worktree: SupermuxWorktreeDTO(
            path: "/w/beta", branch: "beta-branch", isOpen: false
        ))
        model.actions.requestNestedWorktreeRemoval(beta.id, betaRow)
        model.confirmPendingWorktreeRemoval()
        try await wait.until {
            model.worktreeSessions[beta.id]?.store.removal
                == .awaitingForceConfirmation(
                    worktreePath: "/w/beta",
                    branch: "beta-branch",
                    message: "worktree has uncommitted changes"
                )
        }

        // The prompt follows the MOST RECENT request and names its worktree,
        // rather than whichever project the dictionary happened to yield.
        let prompt = try #require(model.forcedWorktreeRemovalPrompt)
        #expect(prompt.projectID == beta.id)
        #expect(prompt.displayName == "beta-branch")
    }

    @Test func aSwipeIsIgnoredWhenNoStoreCouldPerformIt() async throws {
        // Without `supermux.worktrees.v1` (or while collapsed) there is no
        // section-owned store, so raising a dialog whose confirm could only
        // fail would be worse than ignoring the gesture.
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = Task {
            await model.runSession(client: client, hostCapabilities: [Self.projectsCapability])
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }

        model.actions.requestNestedWorktreeRemoval(project.id, looseRow)
        #expect(model.pendingWorktreeRemoval == nil)

        // A confirm arriving with nothing pending is inert, never a crash or
        // a stray delete.
        model.confirmPendingWorktreeRemoval()
        for _ in 0..<10 { await Task.yield() }
        #expect(!client.callLog.contains("worktreeRemove"))
    }
}
