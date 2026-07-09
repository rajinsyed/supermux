import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// The m6-f1 inline-nesting behavior of ``SupermuxProjectsSectionModel``:
/// mac-sidebar-style per-project disclosure (expanded rows project nested
/// workspace/worktree snapshots; collapsed project none), fetch-on-expand +
/// event refetch, phone-local expansion persistence, the detail-screen
/// route, the nested worktree open flow, and the session-lifecycle guards —
/// all against the fake Mac client. Split from
/// `SupermuxProjectsSectionModelTests.swift` (file-length budget).
@MainActor
@Suite struct SupermuxProjectsSectionNestingTests {
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

    /// A model whose expansion state lives in an isolated, throwaway
    /// UserDefaults suite (tests must never touch the real defaults).
    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suiteName = "SupermuxProjectsSectionNestingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func workspaceRow(
        id: String = "workspace-row-1",
        projectID: String,
        name: String = "alpha workspace"
    ) -> SupermuxProjectWorkspaceRowSnapshot {
        SupermuxProjectWorkspaceRowSnapshot(
            id: id,
            projectID: projectID,
            name: name,
            activity: .working,
            hasUnread: false
        )
    }

    // MARK: Inline projection

    @Test func expandedProjectYieldsNestedRowsInMacSidebarShape() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [
            // Opened worktree: represented by its nested WORKSPACE row, so the
            // nested worktree rows must exclude it (mac sidebar's
            // unopened-worktrees rule).
            SupermuxWorktreeDTO(path: "/w/opened", branch: "opened", isOpen: true, workspaceId: "ws-open"),
            SupermuxWorktreeDTO(path: "/w/loose", branch: "loose", isOpen: false),
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
        model.updateWorkspaces([workspaceRow(projectID: project.id)], selectWorkspace: { _ in })

        // Collapsed: no nested worktree rows, but the m6-f2 one-shot count
        // seed still fetches once so the capsule count shows pre-expansion
        // (unopened only: the opened worktree is excluded).
        let collapsed = try #require(model.snapshot.rows.first)
        #expect(collapsed.isExpanded == false)
        #expect(collapsed.nestedWorktrees == SupermuxProjectNestedWorktrees.unavailable)
        try await wait.until { model.snapshot.rows.first?.worktreeCount == 1 }
        #expect(client.worktreesListCallCount == 1)

        // Expanding fetches the worktrees (fetch on expand) and projects the
        // nested rows: open workspaces (shell order) + UNOPENED worktrees
        // (Mac order), mirroring the mac sidebar's nesting.
        model.toggleProjectExpanded(project.id)
        try await wait.until {
            model.snapshot.rows.first?.nestedWorktrees
                == SupermuxProjectNestedWorktrees.loaded([
                    SupermuxWorktreeRowSnapshot(worktree: SupermuxWorktreeDTO(
                        path: "/w/loose", branch: "loose", isOpen: false
                    )),
                ])
        }
        let expanded = try #require(model.snapshot.rows.first)
        #expect(expanded.isExpanded)
        #expect(expanded.openWorkspaces.map(\.id) == ["workspace-row-1"])
        #expect(client.worktreesListCallCount == 2)

        // Collapsing hides the nested rows again and drops the fetch session.
        model.toggleProjectExpanded(project.id)
        let recollapsed = try #require(model.snapshot.rows.first)
        #expect(recollapsed.isExpanded == false)
        #expect(recollapsed.nestedWorktrees == SupermuxProjectNestedWorktrees.unavailable)
    }

    @Test func expandedWorktreesRefetchOnTheWorktreesUpdatedEvent() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [
            SupermuxWorktreeDTO(path: "/w/one", branch: "one"),
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

        model.toggleProjectExpanded(project.id)
        try await wait.until { model.snapshot.rows.first?.worktreeCount == 1 }

        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [
            SupermuxWorktreeDTO(path: "/w/one", branch: "one"),
            SupermuxWorktreeDTO(path: "/w/two", branch: "two"),
        ])
        client.emit(SupermuxMobileEvent(topic: .worktreesUpdated))
        try await wait.until {
            if case .loaded(let rows) = model.snapshot.rows.first?.nestedWorktrees {
                return rows.count == 2
            }
            return false
        }
    }

    @Test func expansionToggleIsInertWithoutTheWorktreesCapability() async throws {
        // Expansion still flips (workspaces can nest), but no worktree RPC is
        // ever issued against a host without supermux.worktrees.v1.
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = Task {
            await model.runSession(client: client, hostCapabilities: [Self.projectsCapability])
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }

        model.toggleProjectExpanded(project.id)
        let row = try #require(model.snapshot.rows.first)
        #expect(row.isExpanded)
        #expect(row.nestedWorktrees == SupermuxProjectNestedWorktrees.unavailable)
        #expect(client.worktreesListCallCount == 0)
    }

    // MARK: Expansion persistence

    @Test func expansionStatePersistsAcrossModelInstancesViaUserDefaults() async throws {
        let project = fixtureProject()
        let defaults = try makeIsolatedDefaults()

        let first = SupermuxProjectsSectionModel(expansionDefaults: defaults)
        first.toggleProjectExpanded(project.id)

        // A fresh model over the SAME defaults (new app launch) resumes the
        // per-project expansion — and fetches the expanded project's
        // worktrees at session start.
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [
            SupermuxWorktreeDTO(path: "/w/one", branch: "one"),
        ])
        let second = SupermuxProjectsSectionModel(expansionDefaults: defaults)
        let session = Task {
            await second.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.worktreesCapability]
            )
        }
        defer { session.cancel() }
        try await wait.until { second.snapshot.rows.first?.isExpanded == true }
        try await wait.until { client.worktreesListCallCount == 1 }

        // Collapsing persists too.
        second.toggleProjectExpanded(project.id)
        let third = SupermuxProjectsSectionModel(expansionDefaults: defaults)
        #expect(third.isProjectExpanded(project.id) == false)
    }

    // MARK: Detail route

    @Test func detailAffordanceRoutesToTheDetailScreen() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = Task {
            await model.runSession(client: client, hostCapabilities: [Self.projectsCapability])
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }

        #expect(model.detailProjectID == nil)
        #expect(model.detailRow == nil)

        model.actions.openProjectDetail(project.id)
        #expect(model.detailProjectID == project.id)
        #expect(model.detailRow?.id == project.id)
        #expect(model.detailRow?.name == "Alpha")

        model.dismissProjectDetail()
        #expect(model.detailProjectID == nil)
        #expect(model.detailRow == nil)
    }

    @Test func navigatingToAWorkspacePopsTheDetailRoute() async throws {
        // A stale `true` on the detail destination binding would swallow the
        // NEXT detail push, so every workspace navigation (nested workspace
        // row, worktree open, preset launch — all share actions.selectWorkspace)
        // must clear the route first.
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = Task {
            await model.runSession(client: client, hostCapabilities: [Self.projectsCapability])
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }

        var selected: [String] = []
        model.updateWorkspaces([], selectWorkspace: { selected.append($0) })

        model.openProjectDetail(project.id)
        #expect(model.detailProjectID == project.id)

        model.actions.selectWorkspace("workspace-row-9")
        #expect(selected == ["workspace-row-9"])
        #expect(model.detailProjectID == nil)
    }

    // MARK: Nested worktree open flow

    @Test func nestedWorktreeTapOpensThroughTheWorktreeOpenFlow() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [
            SupermuxWorktreeDTO(path: "/w/loose", branch: "loose", isOpen: false),
        ])
        client.worktreeOpenResponse = SupermuxWorktreeOpenResponse(workspaceId: "ws-9")
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.worktreesCapability]
            )
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }

        var selectedWorkspaceIDs: [String] = []
        model.updateWorkspaces([], selectWorkspace: { selectedWorkspaceIDs.append($0) })
        model.toggleProjectExpanded(project.id)
        try await wait.until {
            if case .loaded(let rows) = model.snapshot.rows.first?.nestedWorktrees {
                return rows.count == 1
            }
            return false
        }
        guard case .loaded(let nested) = try #require(model.snapshot.rows.first).nestedWorktrees else {
            Issue.record("expected loaded nested worktrees")
            return
        }

        // Unopened worktree: the m2-f2 open flow (worktree.open → navigate).
        model.actions.openNestedWorktree(project.id, try #require(nested.first))
        try await wait.until { selectedWorkspaceIDs == ["ws-9"] }
        #expect(client.callLog.contains("worktreeOpen"))

        // An already-open worktree row navigates straight to its workspace —
        // no second RPC.
        let openCallsBefore = client.callLog.filter { $0 == "worktreeOpen" }.count
        let openRow = SupermuxWorktreeRowSnapshot(worktree: SupermuxWorktreeDTO(
            path: "/w/opened", branch: "opened", isOpen: true, workspaceId: "ws-open"
        ))
        model.actions.openNestedWorktree(project.id, openRow)
        try await wait.until { selectedWorkspaceIDs == ["ws-9", "ws-open"] }
        #expect(client.callLog.filter { $0 == "worktreeOpen" }.count == openCallsBefore)
    }

    @Test func nestedWorktreeOpenFailureSurfacesTheErrorNeverSilently() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [
            SupermuxWorktreeDTO(path: "/w/loose", branch: "loose", isOpen: false),
        ])
        client.worktreeOpenError = SupermuxMacUnavailableError()
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.worktreesCapability]
            )
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }
        model.toggleProjectExpanded(project.id)
        try await wait.until {
            if case .loaded = model.snapshot.rows.first?.nestedWorktrees { return true }
            return false
        }

        model.actions.openNestedWorktree(project.id, SupermuxWorktreeRowSnapshot(
            worktree: SupermuxWorktreeDTO(path: "/w/loose", branch: "loose", isOpen: false)
        ))
        try await wait.until { model.nestedOpenErrorMessage != nil }

        model.dismissNestedOpenError()
        #expect(model.nestedOpenErrorMessage == nil)
    }

    // MARK: Session-lifecycle guards

    @Test func deletedProjectsWorktreeSessionIsPrunedByTheNextProjectsFetch() async throws {
        // A project deleted mac-side loses its row, so its expanded session
        // could never be collapsed away — the authoritative projects list
        // must end it (otherwise it refetches on every worktrees event
        // forever).
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [
            SupermuxWorktreeDTO(path: "/w/one", branch: "one"),
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

        model.toggleProjectExpanded(project.id)
        try await wait.until { model.worktreeSessions[project.id] != nil }

        // The project disappears from the authoritative list.
        client.listResponse = SupermuxProjectsListResponse(projects: [])
        client.emit(SupermuxMobileEvent(topic: .projectsUpdated))
        try await wait.until { model.worktreeSessions[project.id] == nil }

        // Its persisted expansion id is deliberately KEPT (it may belong to
        // another paired Mac); only the live session is pruned.
        #expect(model.isProjectExpanded(project.id))
    }

    @Test func staleInFlightWorktreeOpenNeverNavigatesOrErrorsAfterSessionEnd() async throws {
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        client.worktreesListResponse = SupermuxWorktreesListResponse(worktrees: [
            SupermuxWorktreeDTO(path: "/w/loose", branch: "loose", isOpen: false),
        ])
        client.worktreeOpenResponse = SupermuxWorktreeOpenResponse(workspaceId: "ws-stale")
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.worktreesCapability]
            )
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }

        var selected: [String] = []
        model.updateWorkspaces([], selectWorkspace: { selected.append($0) })
        model.toggleProjectExpanded(project.id)
        try await wait.until { model.worktreeSessions[project.id] != nil }

        // Fire the open, then end the session BEFORE the answer is applied:
        // the old connection's late answer must be dropped.
        model.openNestedWorktree(projectID: project.id, worktree: SupermuxWorktreeRowSnapshot(
            worktree: SupermuxWorktreeDTO(path: "/w/loose", branch: "loose", isOpen: false)
        ))
        model.endSession()

        try await wait.until { client.callLog.contains("worktreeOpen") }
        for _ in 0..<20 { await Task.yield() }
        #expect(selected.isEmpty)
        #expect(model.nestedOpenErrorMessage == nil)
    }

    @Test func naturalSessionTeardownInvalidatesInFlightOpensToo() async throws {
        // The driver's `.task` being cancelled with NO replacement (the list
        // left the screen) runs only runSession's identity-guarded defer —
        // it must bump the generation exactly like endSession(), so a late
        // worktree-open answer is dropped there as well.
        let project = fixtureProject()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [project])
        let model = SupermuxProjectsSectionModel(expansionDefaults: try makeIsolatedDefaults())
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [Self.projectsCapability, Self.worktreesCapability]
            )
        }
        try await wait.until { model.snapshot.hasLoaded }
        let liveGeneration = model.sessionGeneration

        session.cancel()
        client.finishEventStreams()
        try await wait.until { model.snapshot.isVisible == false }
        #expect(model.sessionGeneration > liveGeneration)
    }
}
