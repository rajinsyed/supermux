import CmuxMobileRPC
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// UI-03 for worktrees: store actions send method names + params matching
/// architecture §2 exactly (asserted against the fake's recorded wire calls),
/// and the `dirty_worktree` error path surfaces a confirm-force state — never
/// a silent failure. Plus the list/event sync and capability gate shared with
/// every supermux store.
@MainActor
@Suite struct SupermuxMobileWorktreesStoreTests {
    private static let projectID = "0A6E3E1B-8C1F-4E58-9C1D-2B5F0E7A9C11"

    private static let fixturesA: [SupermuxWorktreeDTO] = [
        SupermuxWorktreeDTO(
            path: "/Users/dev/alpha/.worktrees/fix-login",
            branch: "fix-login",
            isOpen: false,
            pullRequest: SupermuxPullRequestDTO(
                number: 41,
                state: "open",
                url: "https://github.com/acme/app/pull/41"
            )
        ),
    ]

    private static let fixturesB: [SupermuxWorktreeDTO] = [
        SupermuxWorktreeDTO(path: "/Users/dev/alpha/.worktrees/fix-login", branch: "fix-login"),
        SupermuxWorktreeDTO(path: "/Users/dev/alpha/.worktrees/new-idea", branch: "new-idea"),
    ]

    private static let worktreesOnly = SupermuxMobileCapabilities(
        hostCapabilities: [SupermuxMobileCapability.worktreesV1.rawValue]
    )

    private func makeStore(
        fake: FakeSupermuxMacClient,
        capabilities: SupermuxMobileCapabilities = worktreesOnly,
        onWorktreesChanged: (@MainActor (String, Int) -> Void)? = nil
    ) -> SupermuxMobileWorktreesStore {
        SupermuxMobileWorktreesStore(
            client: fake,
            capabilities: capabilities,
            projectID: Self.projectID,
            onWorktreesChanged: onWorktreesChanged,
            idleSleep: { _ in await Task.yield() }
        )
    }

    // MARK: List sync + event-driven refetch

    @Test func syncsWorktreesThenRefetchesOnWorktreesUpdated() async throws {
        let fake = FakeSupermuxMacClient()
        fake.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: Self.fixturesA)
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        try await TestWait().until { store.hasLoaded }
        #expect(store.worktrees == Self.fixturesA)
        // Subscribe-before-fetch, on exactly the worktrees topic.
        #expect(fake.callLog.prefix(2) == ["events", "worktreesList"])
        #expect(fake.subscribedTopicSets.first == [.worktreesUpdated])
        // §2 exact wire shape for the fetch.
        #expect(fake.recordedWireCalls.first?.method == "mobile.supermux.worktrees.list")
        #expect(fake.recordedWireCalls.first?.params == ["project_id": Self.projectID] as NSDictionary)

        fake.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: Self.fixturesB)
        fake.emit(SupermuxMobileEvent(topic: .worktreesUpdated))
        try await TestWait().until { store.worktrees == Self.fixturesB }
        #expect(fake.worktreesListCallCount == 2)
    }

    @Test func fetchFailureSurfacesErrorAndNextEventRecovers() async throws {
        struct Boom: Error {}
        let fake = FakeSupermuxMacClient()
        fake.worktreesListError = Boom()
        let store = makeStore(fake: fake)
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        try await TestWait().until { store.lastErrorDescription != nil }
        #expect(!store.hasLoaded)

        fake.worktreesListError = nil
        fake.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: Self.fixturesA)
        fake.emit(SupermuxMobileEvent(topic: .worktreesUpdated))
        try await TestWait().until { store.hasLoaded }
        #expect(store.lastErrorDescription == nil)
    }

    @Test func reportsWorktreeCountAfterEachSuccessfulFetch() async throws {
        let fake = FakeSupermuxMacClient()
        fake.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: Self.fixturesB)
        var reported: [(projectID: String, count: Int)] = []
        let store = makeStore(fake: fake, onWorktreesChanged: { reported.append(($0, $1)) })
        let runner = Task { await store.run() }
        defer { runner.cancel() }

        try await TestWait().until { store.hasLoaded }
        #expect(reported.last?.projectID == Self.projectID)
        #expect(reported.last?.count == 2)
    }

    // MARK: Capability gate

    @Test func withoutWorktreesCapabilityTheStoreIsInert() async throws {
        let fake = FakeSupermuxMacClient()
        fake.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: Self.fixturesA)
        let store = makeStore(
            fake: fake,
            capabilities: SupermuxMobileCapabilities(hostCapabilities: ["workspace.groups.v1"])
        )
        #expect(!store.showsWorktrees)
        await store.run()
        #expect(fake.callLog.isEmpty)
        #expect(store.worktrees.isEmpty)
    }

    // MARK: UI-03 — create-worktree with AI suggest, exact wire shapes

    @Test func suggestBranchSendsTheExactSuggestBranchWireCall() async throws {
        let fake = FakeSupermuxMacClient()
        fake.suggestBranchResponse = SupermuxBranchSuggestionResponse(
            branchName: "fix-login-flow",
            source: "ai"
        )
        let store = makeStore(fake: fake)

        let suggestion = try await store.suggestBranchName(workspaceName: "Fix login")
        #expect(suggestion.branchName == "fix-login-flow")
        #expect(suggestion.source == "ai")
        #expect(fake.recordedWireCalls.count == 1)
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.worktree.suggest_branch")
        #expect(fake.recordedWireCalls[0].params == ["workspace_name": "Fix login"] as NSDictionary)
    }

    @Test func suggestBranchOmitsABlankWorkspaceName() async throws {
        let fake = FakeSupermuxMacClient()
        let store = makeStore(fake: fake)
        _ = try await store.suggestBranchName(workspaceName: "   ")
        #expect(fake.recordedWireCalls[0].params == [:] as NSDictionary)
    }

    @Test func createWorktreeSendsTheExactCreateWireCallAndRefetches() async throws {
        let fake = FakeSupermuxMacClient()
        fake.worktreeCreateResponse = SupermuxWorktreeCreateResponse(
            worktree: Self.fixturesA[0],
            workspaceId: "5D2C9A44-71B3-4F0E-8E0A-6C4D1F2B3A55"
        )
        fake.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: Self.fixturesA)
        let store = makeStore(fake: fake)

        let response = try await store.createWorktree(
            workspaceName: "Fix login",
            branchName: "fix-login-flow",
            open: true
        )
        #expect(response.workspaceId == "5D2C9A44-71B3-4F0E-8E0A-6C4D1F2B3A55")
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.worktree.create")
        #expect(fake.recordedWireCalls[0].params == [
            "project_id": Self.projectID,
            "workspace_name": "Fix login",
            "branch_name": "fix-login-flow",
            "open": true,
        ] as NSDictionary)
        // The store refreshes its list right after a create so the new
        // worktree shows without waiting for the Mac's poke.
        #expect(fake.worktreesListCallCount == 1)
        #expect(store.worktrees == Self.fixturesA)
    }

    @Test func createWorktreeOmitsBlankOptionalParams() async throws {
        let fake = FakeSupermuxMacClient()
        let store = makeStore(fake: fake)
        _ = try await store.createWorktree(workspaceName: "", branchName: nil, open: false)
        #expect(fake.recordedWireCalls[0].params == [
            "project_id": Self.projectID,
            "open": false,
        ] as NSDictionary)
    }

    @Test func createWorktreeFailureRethrowsForTheSheetToDisplay() async {
        let fake = FakeSupermuxMacClient()
        fake.worktreeCreateError = MobileShellConnectionError.rpcError(
            "invalid_params", "Branch name is invalid"
        )
        let store = makeStore(fake: fake)
        await #expect(throws: (any Error).self) {
            _ = try await store.createWorktree(workspaceName: nil, branchName: "bad..name", open: true)
        }
    }

    // MARK: Open

    @Test func openWorktreeSendsTheExactOpenWireCall() async throws {
        let fake = FakeSupermuxMacClient()
        fake.worktreeOpenResponse = SupermuxWorktreeOpenResponse(
            workspaceId: "7F1E2D3C-4B5A-6978-8899-AABBCCDDEEFF"
        )
        let store = makeStore(fake: fake)

        let workspaceID = try await store.openWorktree(path: Self.fixturesA[0].path)
        #expect(workspaceID == "7F1E2D3C-4B5A-6978-8899-AABBCCDDEEFF")
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.worktree.open")
        #expect(fake.recordedWireCalls[0].params == [
            "project_id": Self.projectID,
            "worktree_path": Self.fixturesA[0].path,
        ] as NSDictionary)
    }

    // MARK: UI-03 — dirty_worktree → confirm-force state machine

    @Test func dirtyWorktreeRemovalSurfacesAConfirmForceStateThenForcedRetrySucceeds() async throws {
        let path = Self.fixturesA[0].path
        let fake = FakeSupermuxMacClient()
        fake.worktreeRemoveError = MobileShellConnectionError.rpcError(
            "dirty_worktree", "Worktree has uncommitted changes"
        )
        let store = makeStore(fake: fake)

        await store.removeWorktree(path: path)
        // NOT a silent failure: the store parks in the confirm-force state.
        #expect(store.removal == .awaitingForceConfirmation(
            worktreePath: path,
            message: "Worktree has uncommitted changes"
        ))
        #expect(fake.recordedWireCalls[0].method == "mobile.supermux.worktree.remove")
        // First attempt never sends force.
        #expect(fake.recordedWireCalls[0].params == [
            "project_id": Self.projectID,
            "worktree_path": path,
        ] as NSDictionary)

        // The user confirms: retry with force: true.
        fake.worktreeRemoveError = nil
        fake.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [])
        await store.removeWorktree(path: path, force: true)
        #expect(store.removal == .idle)
        #expect(fake.recordedWireCalls[1].method == "mobile.supermux.worktree.remove")
        #expect(fake.recordedWireCalls[1].params == [
            "project_id": Self.projectID,
            "worktree_path": path,
            "force": true,
        ] as NSDictionary)
        // Successful removal refreshes the list immediately.
        #expect(fake.worktreesListCallCount == 1)
        #expect(store.worktrees.isEmpty)
    }

    @Test func nonDirtyRemovalErrorSurfacesAsFailedNotConfirmForce() async {
        let path = Self.fixturesA[0].path
        let fake = FakeSupermuxMacClient()
        fake.worktreeRemoveError = MobileShellConnectionError.rpcError(
            "forbidden", "Worktree is not managed by this project"
        )
        let store = makeStore(fake: fake)

        await store.removeWorktree(path: path)
        #expect(store.removal == .failed(
            worktreePath: path,
            message: "Worktree is not managed by this project"
        ))

        store.dismissRemoval()
        #expect(store.removal == .idle)
    }

    @Test func dirtyErrorOnAForcedRemovalIsTerminalNotALoop() async {
        let path = Self.fixturesA[0].path
        let fake = FakeSupermuxMacClient()
        fake.worktreeRemoveError = MobileShellConnectionError.rpcError(
            "dirty_worktree", "Worktree has uncommitted changes"
        )
        let store = makeStore(fake: fake)

        await store.removeWorktree(path: path, force: true)
        #expect(store.removal == .failed(
            worktreePath: path,
            message: "Worktree has uncommitted changes"
        ))
    }

    @Test func successfulRemovalGoesStraightBackToIdle() async throws {
        let path = Self.fixturesA[0].path
        let fake = FakeSupermuxMacClient()
        fake.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [])
        let store = makeStore(fake: fake)

        await store.removeWorktree(path: path)
        #expect(store.removal == .idle)
        #expect(fake.recordedWireCalls[0].params == [
            "project_id": Self.projectID,
            "worktree_path": path,
        ] as NSDictionary)
    }
}
