import Foundation
import SupermuxKit
import Testing

/// In-memory ``SupermuxDirectoryAssociationPersisting`` backend for tests,
/// standing in for the projects model's on-disk store. Normalizes keys the same
/// way the real model does so write/read stays consistent.
@MainActor
private final class StubDirectoryAssociationStore: SupermuxDirectoryAssociationPersisting {
    var directoryAssociations: [String: UUID] = [:]

    func associateDirectory(_ directory: String, with projectId: UUID) {
        directoryAssociations[SupermuxProjectMatcher.normalizedDirectory(directory)] = projectId
    }
}

/// Tests the workspace→project nesting resolver: explicit (session) association,
/// durable directory links that survive a restart, worktree-directory matching,
/// and the rule that an unassociated workspace inside a project root stays
/// standalone.
@MainActor
struct SupermuxWorkspaceAssociationStoreTests {
    private func project(name: String, root: String) -> SupermuxProject {
        SupermuxProject(name: name, rootPath: root)
    }

    @Test func explicitAssociationNestsRegardlessOfDirectory() {
        let store = SupermuxWorkspaceAssociationStore()
        let p = project(name: "a", root: "/repos/a")
        let ws = UUID()
        store.associate(workspaceId: ws, projectId: p.id)
        // Directory is unrelated to the project, but the explicit association wins.
        #expect(store.projectId(forWorkspace: ws, directory: "/elsewhere", in: [p]) == p.id)
    }

    @Test func unassociatedWorkspaceInsideRootStaysStandalone() {
        let store = SupermuxWorkspaceAssociationStore()
        let p = project(name: "a", root: "/repos/a")
        // A workspace whose directory merely sits inside the project root — but
        // was never opened from the project — must NOT nest. This is the
        // "create a workspace without it being under a project" guarantee.
        #expect(store.projectId(forWorkspace: UUID(), directory: "/repos/a", in: [p]) == nil)
        #expect(store.projectId(forWorkspace: UUID(), directory: "/repos/a/src", in: [p]) == nil)
    }

    @Test func worktreeDirectoryNestsWithoutAssociation() {
        let store = SupermuxWorkspaceAssociationStore()
        let p = project(name: "a", root: "/repos/a")
        // Worktrees nest by directory alone, so they survive a restart even
        // though explicit associations do not.
        #expect(store.projectId(forWorkspace: UUID(), directory: "/repos/a/.worktrees/feature", in: [p]) == p.id)
    }

    @Test func staleAssociationToRemovedProjectIsIgnored() {
        let store = SupermuxWorkspaceAssociationStore()
        let p = project(name: "a", root: "/repos/a")
        let ws = UUID()
        store.associate(workspaceId: ws, projectId: UUID())  // project not in the list
        #expect(store.projectId(forWorkspace: ws, directory: "/elsewhere", in: [p]) == nil)
    }

    @Test func forgetRemovesAssociation() {
        let store = SupermuxWorkspaceAssociationStore()
        let p = project(name: "a", root: "/repos/a")
        let ws = UUID()
        store.associate(workspaceId: ws, projectId: p.id)
        store.forget(workspaceId: ws)
        #expect(store.projectId(forWorkspace: ws, directory: "/elsewhere", in: [p]) == nil)
    }

    @Test func mainWorkspaceAtRootReNestsAcrossRestartViaDurableLink() {
        let persistence = StubDirectoryAssociationStore()
        let p = project(name: "a", root: "/repos/a")
        // Session 1: open the project's main workspace (lives at the root).
        let session1 = SupermuxWorkspaceAssociationStore(persistence: persistence)
        session1.associate(workspaceId: UUID(), projectId: p.id, directory: "/repos/a")

        // Session 2 after a restart: a brand-new workspace UUID at the same root,
        // with the session link gone but the durable directory link intact.
        let session2 = SupermuxWorkspaceAssociationStore(persistence: persistence)
        #expect(session2.projectId(forWorkspace: UUID(), directory: "/repos/a", in: [p]) == p.id)
    }

    @Test func durableLinkStillLeavesNeverOpenedRootWorkspaceStandalone() {
        // The "open a workspace without nesting" guarantee must hold even when a
        // durable backend is wired: only directories actually opened from the
        // project get a link, so a never-opened workspace at the root stays out.
        let persistence = StubDirectoryAssociationStore()
        let store = SupermuxWorkspaceAssociationStore(persistence: persistence)
        let p = project(name: "a", root: "/repos/a")
        #expect(store.projectId(forWorkspace: UUID(), directory: "/repos/a", in: [p]) == nil)
    }

    @Test func sessionForgetKeepsDurableLink() {
        // The durable directory link is a project-level fact: forgetting a
        // workspace's session entry (on close) must NOT drop it, so a cancelled
        // close or a sibling workspace at the same directory still nests.
        let persistence = StubDirectoryAssociationStore()
        let p = project(name: "a", root: "/repos/a")
        let store = SupermuxWorkspaceAssociationStore(persistence: persistence)
        let ws = UUID()
        store.associate(workspaceId: ws, projectId: p.id, directory: "/repos/a")
        store.forget(workspaceId: ws)
        // The session link is gone, but the durable directory link re-nests any
        // workspace still at that directory (including the same one if its close
        // was cancelled).
        #expect(store.projectId(forWorkspace: ws, directory: "/repos/a", in: [p]) == p.id)
    }

    @Test func durableLinkToRemovedProjectIsIgnored() {
        let persistence = StubDirectoryAssociationStore()
        let p = project(name: "a", root: "/repos/a")
        let store = SupermuxWorkspaceAssociationStore(persistence: persistence)
        store.associate(workspaceId: UUID(), projectId: p.id, directory: "/repos/a")
        // The project is no longer registered, so the durable link must not nest.
        #expect(store.projectId(forWorkspace: UUID(), directory: "/repos/a", in: []) == nil)
    }

    @Test func standaloneWorkspaceAtRootStaysFlatDespiteDurableLink() {
        // The `+` / New Workspace flow marks every created workspace standalone.
        // Even when the project's root already has a durable directory link (its
        // main workspace was opened earlier), a *different* standalone workspace
        // that inherited the same root directory must stay in the flat list.
        let persistence = StubDirectoryAssociationStore()
        let p = project(name: "a", root: "/repos/a")
        let store = SupermuxWorkspaceAssociationStore(persistence: persistence)
        store.associate(workspaceId: UUID(), projectId: p.id, directory: "/repos/a")
        let plus = UUID()
        store.markStandalone(workspaceId: plus)
        #expect(store.projectId(forWorkspace: plus, directory: "/repos/a", in: [p]) == nil)
    }

    @Test func standaloneWorkspaceInWorktreeDirStaysFlat() {
        // A `+` workspace created while focused in a worktree inherits the
        // worktree directory, which the worktree matcher would otherwise nest.
        // The standalone marking keeps it at the root, matching "the New
        // Workspace button always creates at the root".
        let store = SupermuxWorkspaceAssociationStore()
        let p = project(name: "a", root: "/repos/a")
        let plus = UUID()
        store.markStandalone(workspaceId: plus)
        #expect(store.projectId(forWorkspace: plus, directory: "/repos/a/.worktrees/feature", in: [p]) == nil)
    }

    @Test func associateOverridesStandaloneMarking() {
        // Opening a workspace from a project after it was created (and marked
        // standalone) must re-nest it: the project opener calls `associate`
        // right after `addWorkspace`.
        let store = SupermuxWorkspaceAssociationStore()
        let p = project(name: "a", root: "/repos/a")
        let ws = UUID()
        store.markStandalone(workspaceId: ws)
        store.associate(workspaceId: ws, projectId: p.id, directory: "/repos/a")
        #expect(store.projectId(forWorkspace: ws, directory: "/repos/a", in: [p]) == p.id)
    }

    @Test func forgetClearsStandaloneMarking() {
        // A reused/closed workspace id must not stay pinned standalone forever.
        let store = SupermuxWorkspaceAssociationStore()
        let p = project(name: "a", root: "/repos/a")
        let ws = UUID()
        store.markStandalone(workspaceId: ws)
        store.forget(workspaceId: ws)
        // With the standalone marking cleared, directory-based nesting applies
        // again (here: the worktree matcher).
        #expect(store.projectId(forWorkspace: ws, directory: "/repos/a/.worktrees/feature", in: [p]) == p.id)
    }
}
