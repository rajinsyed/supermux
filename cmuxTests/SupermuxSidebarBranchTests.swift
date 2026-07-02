import XCTest
// `SidebarGitBranchState` is public in CmuxSidebar; import it explicitly (like
// SidebarOrderingTests) so this compiles in the plain-`cmux` unit config and not
// only when `cmux_DEV` happens to re-export it.
import CmuxSidebar
import SupermuxKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the supermux project-nested workspace row branch
/// subtitle (`SupermuxAppGlue`'s `SupermuxOpenWorkspace.branch`).
///
/// Bug: "the branch name in the workspace tab goes away when the browser tab is
/// open." The row used to read `workspace.gitBranch`, which only mirrors the
/// *focused* panel's branch — so focusing a branchless surface (a browser tab)
/// cleared it. The fix reads `workspace.supermuxSidebarBranch`, which derives
/// from the per-panel, display-ordered branches that persist across focus
/// changes (the same source cmux's own sidebar rows use).
@MainActor
final class SupermuxSidebarBranchTests: XCTestCase {
    func testSidebarBranchPersistsWhenBrowserTabIsFocused() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let terminalPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: terminalPanelId))

        workspace.updatePanelGitBranch(panelId: terminalPanelId, branch: "feature/x", isDirty: false)
        XCTAssertEqual(
            rowBranch(for: workspace),
            "feature/x",
            "Branch should display while the terminal is focused."
        )

        let browserPanel = try XCTUnwrap(
            workspace.newBrowserSurface(inPane: paneId, focus: true),
            "Expected the browser surface to be created."
        )
        XCTAssertEqual(workspace.focusedPanelId, browserPanel.id)

        // The repro condition: focusing a branchless browser clears the
        // workspace-level focused-branch mirror that the row used to read.
        XCTAssertNil(
            workspace.gitBranch,
            "Focusing a browser tab is expected to clear the focused-panel gitBranch mirror."
        )

        // The fix: the row the user sees must still carry the terminal's
        // branch, which persists per-panel regardless of which surface is
        // focused. Asserting the built snapshot (not the helper) guards the
        // actual SupermuxProjectsMount read-site that caused the bug.
        XCTAssertEqual(
            rowBranch(for: workspace),
            "feature/x",
            "Branch subtitle must persist when a browser tab is focused."
        )
    }

    func testSidebarBranchFallsBackToWorkspaceBranchWhenNoPanelReportsOne() throws {
        let workspace = Workspace(title: "Test")
        workspace.gitBranch = SidebarGitBranchState(branch: "main", isDirty: false)

        XCTAssertEqual(
            rowBranch(for: workspace),
            "main",
            "With no per-panel branches, the row should fall back to the workspace-level branch."
        )
    }

    /// Renaming a project-nested workspace must re-title its row. The supermux
    /// "Rename Workspace…" action routes through `onRenameWorkspace` →
    /// `TabManager.setCustomTitle`, and the nested row reads
    /// `customTitle ?? title` via ``SupermuxWorkspaceRow/snapshot(for:isSelected:projectId:isRunning:)``.
    /// This guards that exact path, including the blank-name clear that reverts
    /// the row to the process title.
    func testSidebarTitleReflectsRenameAndBlankClears() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        // Baseline: with no custom title the row shows the process title.
        XCTAssertNil(workspace.customTitle)
        let processTitle = rowTitle(for: workspace)

        manager.setCustomTitle(tabId: workspace.id, title: "Renamed Workspace")
        XCTAssertEqual(workspace.customTitle, "Renamed Workspace")
        XCTAssertEqual(
            rowTitle(for: workspace),
            "Renamed Workspace",
            "The nested row must show the custom title after a rename."
        )

        // A blank/whitespace name clears the custom title (Workspace.setCustomTitle
        // trims to nil) and the row reverts to the process title.
        manager.setCustomTitle(tabId: workspace.id, title: "   ")
        XCTAssertNil(workspace.customTitle, "A blank rename clears the custom title.")
        XCTAssertEqual(
            rowTitle(for: workspace),
            processTitle,
            "Clearing the custom title reverts the row to the process title."
        )
    }

    /// Standalone (non-project) workspaces feed only their `directory` into the
    /// Projects section (PR-probe target exclusion), so their snapshot must
    /// carry identity fields verbatim while skipping the expensive branch/PR/
    /// activity resolution the full mapping pays per render.
    func testStandaloneSnapshotCarriesIdentityAndSkipsExpensiveResolution() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let terminalPanelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.updatePanelGitBranch(panelId: terminalPanelId, branch: "feature/x", isDirty: false)

        let snapshot = SupermuxWorkspaceRow.standaloneSnapshot(for: workspace, isSelected: true)
        XCTAssertEqual(snapshot.id, workspace.id)
        XCTAssertEqual(snapshot.title, workspace.title)
        XCTAssertEqual(snapshot.directory, workspace.currentDirectory)
        XCTAssertTrue(snapshot.isSelected)
        XCTAssertNil(snapshot.projectId, "Standalone snapshots never nest under a project.")
        XCTAssertNil(snapshot.branch, "Branch resolution is skipped for rows the section never renders.")
        XCTAssertNil(snapshot.pullRequest)
        XCTAssertEqual(snapshot.activity, .idle)
        XCTAssertFalse(snapshot.isRunning)
    }

    /// The branch the user actually sees, built through the production
    /// ``SupermuxWorkspaceRow`` mapping used by ``SupermuxProjectsMount``.
    private func rowBranch(for workspace: Workspace) -> String? {
        SupermuxWorkspaceRow.snapshot(
            for: workspace,
            isSelected: false,
            projectId: nil,
            isRunning: false
        ).branch
    }

    /// The title the user actually sees on a project-nested row, built through
    /// the production ``SupermuxWorkspaceRow`` mapping used by ``SupermuxProjectsMount``.
    private func rowTitle(for workspace: Workspace) -> String {
        SupermuxWorkspaceRow.snapshot(
            for: workspace,
            isSelected: false,
            projectId: nil,
            isRunning: false
        ).title
    }
}

/// In-memory ``SupermuxDirectoryAssociationPersisting`` backend, standing in
/// for the projects model so tests can mutate the durable directory map
/// *directly* — the way the model's sibling-build `adopt()` fold-in and
/// `performLoad` completion do, with no association-store revision bump.
@MainActor
private final class StubDirectoryAssociationStore: SupermuxDirectoryAssociationPersisting {
    var directoryAssociations: [String: UUID] = [:]

    func associateDirectory(_ directory: String, with projectId: UUID) {
        directoryAssociations[SupermuxProjectMatcher.normalizedDirectory(directory)] = projectId
    }
}

/// Behavior coverage for the memoizing project resolution behind
/// ``SupermuxMainListFilter`` (`SupermuxProjectResolutionCache`).
///
/// The cache exists because the per-workspace resolution does O(tabs × projects)
/// NSString path normalization inside `VerticalTabsSidebar.body` and the
/// Projects mount's body; it must stay invisible — an association-store
/// mutation, a durable directory-map change that bypasses the store, a
/// workspace directory change, or a project-set change must each be reflected
/// by the very next pass.
@MainActor
final class SupermuxProjectResolutionCacheTests: XCTestCase {
    private let projectRoot = "/tmp/supermux-filter-tests/proj"

    private func makeProject() -> SupermuxProject {
        SupermuxProject(name: "Proj", rootPath: projectRoot)
    }

    func testNoProjectsPassesEverythingThrough() {
        let cache = SupermuxProjectResolutionCache()
        let store = SupermuxWorkspaceAssociationStore()
        let workspace = Workspace(title: "Loose", workingDirectory: projectRoot + "/.worktrees/wt1")

        // Even a worktree-shaped directory stays visible with no projects.
        XCTAssertEqual(
            cache.filter([workspace], projects: [], associations: store).map(\.id),
            [workspace.id]
        )
    }

    func testGroupedWorkspaceIsNeverFiltered() {
        let cache = SupermuxProjectResolutionCache()
        let store = SupermuxWorkspaceAssociationStore()
        let workspace = Workspace(title: "Grouped", workingDirectory: projectRoot + "/.worktrees/wt1")
        workspace.groupId = UUID()

        // The directory matches the project's worktrees dir, but cmux-grouped
        // workspaces are always left to the group UI.
        XCTAssertEqual(
            cache.filter([workspace], projects: [makeProject()], associations: store).map(\.id),
            [workspace.id]
        )
    }

    func testWorktreeWorkspaceIsHiddenAndStandaloneStays() {
        let cache = SupermuxProjectResolutionCache()
        let store = SupermuxWorkspaceAssociationStore()
        let project = makeProject()
        let worktree = Workspace(title: "WT", workingDirectory: projectRoot + "/.worktrees/wt1")
        let loose = Workspace(title: "Loose", workingDirectory: "/tmp/supermux-filter-tests/elsewhere")

        XCTAssertEqual(
            cache.filter([worktree, loose], projects: [project], associations: store).map(\.id),
            [loose.id],
            "A worktree-dir workspace nests under the project; the loose one stays."
        )
    }

    func testAssociationMutationInvalidatesCachedDecision() {
        let cache = SupermuxProjectResolutionCache()
        let store = SupermuxWorkspaceAssociationStore()
        let project = makeProject()
        let workspace = Workspace(title: "W", workingDirectory: "/tmp/supermux-filter-tests/elsewhere")

        // Two passes so the second is served from the memo.
        XCTAssertEqual(cache.filter([workspace], projects: [project], associations: store).count, 1)
        XCTAssertEqual(cache.filter([workspace], projects: [project], associations: store).count, 1)

        store.associate(workspaceId: workspace.id, projectId: project.id)
        XCTAssertTrue(
            cache.filter([workspace], projects: [project], associations: store).isEmpty,
            "associate() after a cached pass must flush the memo (observation tracking)."
        )

        store.forget(workspaceId: workspace.id)
        XCTAssertEqual(
            cache.filter([workspace], projects: [project], associations: store).count,
            1,
            "forget() must re-show the workspace on the next pass."
        )
    }

    func testDirectoryChangeRecomputesJustThatEntry() {
        let cache = SupermuxProjectResolutionCache()
        let store = SupermuxWorkspaceAssociationStore()
        let project = makeProject()
        let workspace = Workspace(title: "W", workingDirectory: "/tmp/supermux-filter-tests/elsewhere")

        XCTAssertEqual(cache.filter([workspace], projects: [project], associations: store).count, 1)

        // Moving into the project's worktrees dir must drop the stale entry
        // (keyed by the raw directory string) and hide the workspace.
        workspace.currentDirectory = projectRoot + "/.worktrees/wt1"
        XCTAssertTrue(cache.filter([workspace], projects: [project], associations: store).isEmpty)
    }

    func testProjectSetChangeFlushesTheCache() {
        let cache = SupermuxProjectResolutionCache()
        let store = SupermuxWorkspaceAssociationStore()
        let unrelated = SupermuxProject(name: "Other", rootPath: "/tmp/supermux-filter-tests/other")
        let workspace = Workspace(title: "W", workingDirectory: projectRoot + "/.worktrees/wt1")

        XCTAssertEqual(
            cache.filter([workspace], projects: [unrelated], associations: store).count,
            1,
            "No registered project owns the directory yet."
        )
        XCTAssertTrue(
            cache.filter([workspace], projects: [unrelated, makeProject()], associations: store).isEmpty,
            "Registering the owning project must recompute the cached decision."
        )
    }

    /// Regression: the durable directory→project map can change with NO store
    /// revision bump and an unchanged projects array — the projects model
    /// rewrites it directly on sibling-build `adopt()` fold-ins and
    /// `performLoad`'s actor-hop completion. The cache's by-value compare of
    /// `durableDirectoryAssociations` must catch that; keying off revision +
    /// projects alone left the stale decision rendering the workspace in both
    /// the flat list and the Projects section.
    func testDurableDirectoryOnlyChangeInvalidatesCachedDecision() {
        let cache = SupermuxProjectResolutionCache()
        let persistence = StubDirectoryAssociationStore()
        let store = SupermuxWorkspaceAssociationStore(persistence: persistence)
        let project = makeProject()
        let workspace = Workspace(title: "Main", workingDirectory: projectRoot)

        // At the project root with no links: standalone, and cached as such
        // (two passes so the second is served from the memo).
        XCTAssertEqual(cache.filter([workspace], projects: [project], associations: store).count, 1)
        XCTAssertEqual(cache.filter([workspace], projects: [project], associations: store).count, 1)

        // Mutate the durable map behind the store's back: same projects array,
        // no revision bump.
        persistence.directoryAssociations[
            SupermuxProjectMatcher.normalizedDirectory(projectRoot)
        ] = project.id
        XCTAssertEqual(store.revision, 0, "Precondition: the direct write must not bump the revision.")
        XCTAssertTrue(
            cache.filter([workspace], projects: [project], associations: store).isEmpty,
            "A durable-map-only change must invalidate the cached resolution on the next pass."
        )
    }

    /// Regression: one static cache shared by every window let the smaller
    /// window's staleness pruning evict the larger window's entries on every
    /// pass (each window passes its OWN tab list) — permanent recompute
    /// thrash. The filter hands out one cache per `TabManager`, stable across
    /// lookups, so window B's passes can never touch window A's entries.
    func testEachTabManagerGetsItsOwnStableCache() {
        let managerA = TabManager()
        let managerB = TabManager()

        let cacheA = SupermuxMainListFilter.resolutionCache(for: managerA)
        let cacheB = SupermuxMainListFilter.resolutionCache(for: managerB)
        XCTAssertFalse(cacheA === cacheB, "Each window's TabManager must get an independent cache.")
        XCTAssertTrue(
            SupermuxMainListFilter.resolutionCache(for: managerA) === cacheA,
            "Repeated lookups must return the same per-window instance, not a fresh cache."
        )
        XCTAssertTrue(SupermuxMainListFilter.resolutionCache(for: managerB) === cacheB)
    }

    /// The memoized `projectId` resolution (consumed by the Projects mount)
    /// must round-trip: identical answers on the compute and memo-hit passes,
    /// agree with the flat-list filter (hidden ⇔ non-nil), and track
    /// association changes.
    func testMemoizedProjectIdRoundTripsAndAgreesWithFilter() {
        let cache = SupermuxProjectResolutionCache()
        let store = SupermuxWorkspaceAssociationStore()
        let project = makeProject()
        let worktree = Workspace(title: "WT", workingDirectory: projectRoot + "/.worktrees/wt1")
        let loose = Workspace(title: "Loose", workingDirectory: "/tmp/supermux-filter-tests/elsewhere")

        // First pass computes, second is served from the memo — both must agree.
        for pass in 1...2 {
            XCTAssertEqual(
                cache.projectId(forWorkspace: worktree, projects: [project], associations: store),
                project.id,
                "Worktree resolution must survive pass \(pass)."
            )
            XCTAssertNil(
                cache.projectId(forWorkspace: loose, projects: [project], associations: store),
                "Standalone resolution must survive pass \(pass)."
            )
        }
        // The flat list is defined on top of the same resolution: hidden
        // exactly when projectId is non-nil.
        XCTAssertEqual(
            cache.filter([worktree, loose], projects: [project], associations: store).map(\.id),
            [loose.id]
        )

        // Association changes must flow through the memoized resolution too.
        store.associate(workspaceId: loose.id, projectId: project.id)
        XCTAssertEqual(
            cache.projectId(forWorkspace: loose, projects: [project], associations: store),
            project.id,
            "associate() after a memo hit must be visible on the next resolution."
        )
    }
}
