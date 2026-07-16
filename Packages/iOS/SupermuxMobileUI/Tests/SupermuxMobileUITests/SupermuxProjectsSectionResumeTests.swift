import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// Push/pop list-state preservation (m6-f3): navigating into a workspace and
/// back must NOT visibly reload the Projects section or reset its content.
///
/// Field bug this pins: pushing ANY navigation destination over the shell's
/// `List` (a workspace row, not just the project detail) cancels the section
/// driver's structured `.task`; `runSession`'s defer used to tear the whole
/// session down whenever no project DETAIL was routed — blanking the section
/// (`snapshot == .hidden`), un-hiding the project-owned rows in the flat
/// list, and forcing the post-pop rerun to rebuild a fresh store through a
/// visible "Loading projects…" placeholder. Content churn on pop also threw
/// away the `List`'s scroll position.
///
/// New contract (stale-while-revalidate):
/// 1. Cancellation PAUSES the session — stores stay installed, the snapshot
///    keeps rendering the loaded content.
/// 2. Re-running the driver task for the SAME connection identity RESUMES
///    the retained stores (identical object, `hasLoaded` never regresses)
///    and revalidates silently in the background.
/// 3. A DIFFERENT connection identity still replaces the session wholesale.
@MainActor
@Suite struct SupermuxProjectsSectionResumeTests {
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
            colorHex: "#3b82f6",
            iconSymbol: "folder",
            hasCustomIcon: false
        )
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "SupermuxProjectsSectionResumeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// Starts a session task with a connection identity and waits for the
    /// first load.
    private func startSession(
        _ model: SupermuxProjectsSectionModel,
        client: FakeSupermuxMacClient,
        connectionID: AnyHashable,
        capabilities: Set<String> = [projectsCapability]
    ) async throws -> Task<Void, Never> {
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: capabilities,
                connectionID: connectionID
            )
        }
        try await wait.until { model.snapshot.hasLoaded }
        return session
    }

    // MARK: 1 — cancellation pauses instead of tearing down

    @Test func pushCancellationKeepsTheLoadedSnapshotRendering() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(model, client: client, connectionID: "conn-1")

        // A workspace push covers the list; SwiftUI cancels the driver's
        // `.task`. No project detail is routed.
        session.cancel()
        await session.value

        // The section must keep rendering its loaded content — never regress
        // to hidden (which would also un-hide project-owned rows in the flat
        // list) or to a loading placeholder.
        #expect(model.store != nil)
        #expect(model.snapshot.isVisible)
        #expect(model.snapshot.hasLoaded)
        #expect(model.snapshot.rows.map(\.id) == [project.id])
    }

    // MARK: 2 — pop resumes the SAME stores, revalidating silently

    @Test func popResumesTheRetainedStoreWithoutAnInterveningLoadingState() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(model, client: client, connectionID: "conn-1")

        session.cancel()
        await session.value
        let retainedStore = try #require(model.store)

        // Pop: the driver's `.task` re-runs with the SAME connection key.
        let resumed = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability],
                connectionID: "conn-1"
            )
        }
        defer { resumed.cancel() }

        // Immediately (before the background refetch lands): still the same
        // loaded snapshot. Store identity proves `hasLoaded` never regressed —
        // nothing ever sets it back to false on a live store.
        #expect(model.store === retainedStore)
        #expect(model.snapshot.hasLoaded)
        #expect(model.snapshot.rows.map(\.id) == [project.id])

        // The resume revalidates in the background (a second projects fetch
        // on the same store), still without swapping the store.
        try await wait.until { client.projectsListCallCount >= 2 }
        #expect(model.store === retainedStore)
        #expect(model.snapshot.hasLoaded)
    }

    @Test func backgroundRevalidationKeepsRowIdentityStable() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(model, client: client, connectionID: "conn-1")

        session.cancel()
        await session.value

        // Mac-side changes while the workspace was open: Alpha renamed (same
        // id) and Beta added.
        let beta = fixtureProject(id: "22222222-2222-2222-2222-222222222222", name: "Beta")
        client.listResponse = SupermuxProjectsListResponse(
            projects: [fixtureProject(name: "Alpha Renamed"), beta]
        )

        let resumed = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability],
                connectionID: "conn-1"
            )
        }
        defer { resumed.cancel() }

        // Stale content renders first (never a placeholder)…
        #expect(model.snapshot.rows.map(\.name) == ["Alpha"])
        // …then the silent refresh lands with STABLE row ids (the `List`'s
        // scroll anchor row keeps its identity).
        try await wait.until { model.snapshot.rows.count == 2 }
        #expect(model.snapshot.rows.map(\.id) == [project.id, beta.id])
        #expect(model.snapshot.rows.map(\.name) == ["Alpha Renamed", "Beta"])
        #expect(model.snapshot.hasLoaded)
    }

    @Test func expandedProjectsNestedWorktreesSurviveThePushPopRoundTrip() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [
            SupermuxWorktreeDTO(path: "/w/loose", branch: "loose", isOpen: false),
        ])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(
            model,
            client: client,
            connectionID: "conn-1",
            capabilities: [Self.projectsCapability, Self.worktreesCapability]
        )

        model.toggleProjectExpanded(project.id)
        try await wait.until {
            if case .loaded(let rows) = model.snapshot.rows.first?.nestedWorktrees {
                return !rows.isEmpty
            }
            return false
        }
        let retainedWorktreeStore = try #require(model.worktreeSessions[project.id]?.store)

        session.cancel()
        await session.value

        // Push + pop: the nested slice never flashes back to loading.
        guard case .loaded(let pausedRows) = model.snapshot.rows.first?.nestedWorktrees else {
            Issue.record("nested worktrees regressed while paused: \(String(describing: model.snapshot.rows.first?.nestedWorktrees))")
            return
        }
        #expect(pausedRows.map(\.path) == ["/w/loose"])

        let resumed = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.worktreesCapability],
                connectionID: "conn-1"
            )
        }
        defer { resumed.cancel() }
        #expect(model.worktreeSessions[project.id]?.store === retainedWorktreeStore)
        guard case .loaded = model.snapshot.rows.first?.nestedWorktrees else {
            Issue.record("nested worktrees regressed on resume")
            return
        }
    }

    @Test func resumeKeepsTheRetainedSessionsCallbacksWorking() async throws {
        // The retained store's `onProjectsChanged` closure captured the
        // session generation at creation. Pausing/resuming must NOT bump the
        // generation, or orphan-session pruning and count seeding would die
        // for the rest of the session.
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(
            model,
            client: client,
            connectionID: "conn-1",
            capabilities: [Self.projectsCapability, Self.worktreesCapability]
        )

        model.toggleProjectExpanded(project.id)
        try await wait.until { model.worktreeSessions[project.id] != nil }
        let liveGeneration = model.sessionGeneration

        session.cancel()
        await session.value
        #expect(model.sessionGeneration == liveGeneration)

        let resumed = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.worktreesCapability],
                connectionID: "conn-1"
            )
        }
        defer { resumed.cancel() }
        #expect(model.sessionGeneration == liveGeneration)

        // The project disappears mac-side AFTER the resume: the retained
        // store's generation-guarded prune must still fire.
        client.listResponse = SupermuxProjectsListResponse(projects: [])
        client.emit(SupermuxMobileEvent(topic: .projectsUpdated))
        try await wait.until { model.worktreeSessions[project.id] == nil }
    }

    @Test func pushPausesEveryEventLoopWhileKeepingLoadedContent() async throws {
        // While covered, the section must not keep polling (or re-dialling
        // a dead connection) in the background: ALL loops pause — the
        // worktree ones included — but the loaded content keeps rendering.
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [
            SupermuxWorktreeDTO(path: "/w/loose", branch: "loose", isOpen: false),
        ])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(
            model,
            client: client,
            connectionID: "conn-1",
            capabilities: [Self.projectsCapability, Self.worktreesCapability]
        )
        model.toggleProjectExpanded(project.id)
        try await wait.until {
            if case .loaded = model.snapshot.rows.first?.nestedWorktrees { return true }
            return false
        }
        let projectsCalls = client.projectsListCallCount
        let worktreesCalls = client.worktreesListCallCount

        session.cancel()
        await session.value

        // Paused: the worktree loop task is gone (nothing polls), yet the
        // store — and its loaded rows — remain.
        let pausedSession = try #require(model.worktreeSessions[project.id])
        #expect(pausedSession.task == nil)
        guard case .loaded = model.snapshot.rows.first?.nestedWorktrees else {
            Issue.record("nested rows regressed while paused")
            return
        }
        client.emit(SupermuxMobileEvent(topic: .projectsUpdated))
        client.emit(SupermuxMobileEvent(topic: .worktreesUpdated))
        for _ in 0..<20 { await Task.yield() }
        #expect(client.projectsListCallCount == projectsCalls)
        #expect(client.worktreesListCallCount == worktreesCalls)

        // Resume: both loops restart and silently revalidate.
        let resumed = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.worktreesCapability],
                connectionID: "conn-1"
            )
        }
        defer { resumed.cancel() }
        try await wait.until {
            client.projectsListCallCount > projectsCalls
                && client.worktreesListCallCount > worktreesCalls
        }
        #expect(model.worktreeSessions[project.id]?.task != nil)
    }

    @Test func rapidPopReentryChainsTheLoopsWithoutDeadlocking() async throws {
        // A pop can re-enter runSession before the push-cancelled loops
        // finish unwinding: the new loops chain behind the old ones
        // (single-flight — one store never runs two subscriptions
        // concurrently) and must still come up and revalidate.
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(model, client: client, connectionID: "conn-1")
        let retainedStore = try #require(model.store)
        let calls = client.projectsListCallCount

        // Cancel WITHOUT awaiting the unwind — resume immediately.
        session.cancel()
        let resumed = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability],
                connectionID: "conn-1"
            )
        }
        defer { resumed.cancel() }

        try await wait.until { client.projectsListCallCount > calls }
        #expect(model.store === retainedStore)
        #expect(model.snapshot.hasLoaded)
        #expect(model.snapshot.rows.map(\.id) == [project.id])
    }

    @Test func aReplacedSessionsWorktreeStoreCannotOverwriteTheNewCounts() async throws {
        // A worktree store of a REPLACED session can outlive it (an
        // in-flight open, or a pushed detail screen across a reconnect) and
        // refetches internally before answering — its late count callback
        // must be dropped, never overwriting the new session's badge.
        let project = fixtureProject()
        let client1 = FakeSupermuxMacClient()
        client1.listResponse = SupermuxProjectsListResponse(projects: [project])
        client1.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [
            SupermuxWorktreeDTO(path: "/w/a", branch: "a", isOpen: false),
            SupermuxWorktreeDTO(path: "/w/b", branch: "b", isOpen: false),
        ])
        client1.worktreeOpenResponse = SupermuxWorktreeOpenResponse(workspaceId: "ws-1")
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(
            model,
            client: client1,
            connectionID: "conn-1",
            capabilities: [Self.projectsCapability, Self.worktreesCapability]
        )
        try await wait.until { model.snapshot.rows.first?.worktreeCount == 2 }
        let oldStore = try #require(model.makeWorktreesStore(forProjectID: project.id))
        session.cancel()
        await session.value

        // Reconnect to a Mac state with NO unopened worktrees.
        let client2 = FakeSupermuxMacClient()
        client2.listResponse = SupermuxProjectsListResponse(projects: [project])
        client2.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [])
        let session2 = Task {
            await model.runSession(
                client: client2,
                hostCapabilities: [Self.projectsCapability, Self.worktreesCapability],
                connectionID: "conn-2"
            )
        }
        defer { session2.cancel() }
        try await wait.until { model.snapshot.rows.first?.worktreeCount == 0 }

        // The old store's late answer (open → internal refetch → callback
        // with client1's 2-worktree list) lands AFTER the replacement.
        _ = try? await oldStore.openWorktree(path: "/w/a")
        for _ in 0..<20 { await Task.yield() }
        #expect(model.snapshot.rows.first?.worktreeCount == 0)
    }

    // MARK: 3 — a different connection still replaces wholesale

    @Test func aDifferentConnectionKeyReplacesTheSessionWholesale() async throws {
        let client1 = FakeSupermuxMacClient()
        client1.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(model, client: client1, connectionID: "conn-1")

        session.cancel()
        await session.value
        let retainedStore = try #require(model.store)

        // Reconnect: new client, new key — never resume across connections.
        // (The retained store still reports `hasLoaded`, so wait on the
        // store swap itself, not on a load flag.)
        let client2 = FakeSupermuxMacClient()
        client2.listResponse = SupermuxProjectsListResponse(
            projects: [fixtureProject(id: "33333333-3333-3333-3333-333333333333", name: "Gamma")]
        )
        let session2 = Task {
            await model.runSession(
                client: client2,
                hostCapabilities: [Self.projectsCapability],
                connectionID: "conn-2"
            )
        }
        defer { session2.cancel() }

        try await wait.until { model.store !== retainedStore && model.store != nil }
        try await wait.until { model.snapshot.rows.map(\.name) == ["Gamma"] }
        #expect(client2.projectsListCallCount == 1)
    }

    @Test func endSessionStillHidesTheSectionAndForgetsTheConnection() async throws {
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = try await startSession(model, client: client, connectionID: "conn-1")
        defer { session.cancel() }

        // Hard disconnect: the driver re-runs with `nil` and ends the session.
        model.endSession()
        #expect(model.store == nil)
        #expect(model.snapshot == .hidden)

        // A later session with the SAME key must be a FRESH session (the
        // retained one is gone), not a resume of freed state.
        let client2 = FakeSupermuxMacClient()
        client2.listResponse = SupermuxProjectsListResponse(projects: [fixtureProject()])
        let session2 = try await startSession(model, client: client2, connectionID: "conn-1")
        defer { session2.cancel() }
        #expect(model.store != nil)
        #expect(client2.projectsListCallCount == 1)
    }
}
