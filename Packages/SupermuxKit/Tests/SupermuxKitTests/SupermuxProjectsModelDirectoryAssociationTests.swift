import Foundation
import Testing
@testable import SupermuxKit

/// Persistence tests for the durable directory→project links owned by
/// ``SupermuxProjectsModel``: they survive a reload, drop links to projects that
/// no longer exist on load, and are pruned when their project is removed.
///
/// The model is `@MainActor`, so the suite is too. Each test uses a throwaway
/// on-disk store.
@MainActor
struct SupermuxProjectsModelDirectoryAssociationTests {
    private func freshFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("projects.json")
    }

    private func makeModel(store: SupermuxProjectStore) -> SupermuxProjectsModel {
        SupermuxProjectsModel(store: store, worktreeService: SupermuxGitWorktreeService())
    }

    /// Polls the store until its persisted directory-link count matches, so the
    /// model's fire-and-forget persistence Task has a chance to flush.
    private func waitForPersistedAssociationCount(
        _ store: SupermuxProjectStore,
        expected: Int
    ) async -> [String: UUID]? {
        for _ in 0..<200 {
            let file = await store.load()
            if (file.directoryAssociations?.count ?? 0) == expected { return file.directoryAssociations }
            await Task.yield()
        }
        return await store.load().directoryAssociations
    }

    @Test func loadsStoredLinksForExistingProjects() async throws {
        let url = freshFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let project = SupermuxProject(name: "a", rootPath: "/repos/a")
        let store = SupermuxProjectStore(fileURL: url)
        try await store.save(SupermuxProjectsFile(
            version: 3,
            projects: [project],
            directoryAssociations: ["/repos/a": project.id]
        ))
        let model = makeModel(store: store)

        await model.loadIfNeeded()

        #expect(model.directoryAssociations == ["/repos/a": project.id])
    }

    @Test func dropsLinksToUnknownProjectsOnLoad() async throws {
        let url = freshFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let project = SupermuxProject(name: "a", rootPath: "/repos/a")
        let store = SupermuxProjectStore(fileURL: url)
        // One link points at a project that is not registered; it must be pruned.
        try await store.save(SupermuxProjectsFile(
            version: 3,
            projects: [project],
            directoryAssociations: ["/repos/a": project.id, "/repos/ghost": UUID()]
        ))
        let model = makeModel(store: store)

        await model.loadIfNeeded()

        #expect(model.directoryAssociations == ["/repos/a": project.id])
        // The prune is written back so the stale link doesn't linger on disk.
        let persisted = await waitForPersistedAssociationCount(store, expected: 1)
        #expect(persisted == ["/repos/a": project.id])
    }

    @Test func associateDirectoryPersistsAcrossReload() async throws {
        let url = freshFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let project = SupermuxProject(name: "a", rootPath: "/repos/a")
        let store = SupermuxProjectStore(fileURL: url)
        try await store.save(SupermuxProjectsFile(version: 3, projects: [project]))
        let model = makeModel(store: store)
        await model.loadIfNeeded()

        model.associateDirectory("/repos/a", with: project.id)
        _ = await waitForPersistedAssociationCount(store, expected: 1)

        // A fresh store + model on the same file must observe the saved link.
        let reloadedStore = SupermuxProjectStore(fileURL: url)
        let reloaded = makeModel(store: reloadedStore)
        await reloaded.loadIfNeeded()
        #expect(reloaded.directoryAssociations == ["/repos/a": project.id])
    }

    @Test func associateDirectorySkipsWorktreePaths() async throws {
        let url = freshFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let project = SupermuxProject(name: "a", rootPath: "/repos/a")
        let store = SupermuxProjectStore(fileURL: url)
        try await store.save(SupermuxProjectsFile(version: 3, projects: [project]))
        let model = makeModel(store: store)
        await model.loadIfNeeded()

        // A worktree path nests structurally, so no durable link is written.
        let worktreePath = (project.worktreesDirPath as NSString).appendingPathComponent("feature")
        model.associateDirectory(worktreePath, with: project.id)
        #expect(model.directoryAssociations.isEmpty)

        // The project root has no structural signal, so it IS persisted.
        model.associateDirectory(project.rootPath, with: project.id)
        let rootKey = SupermuxProjectMatcher.normalizedDirectory(project.rootPath)
        #expect(model.directoryAssociations == [rootKey: project.id])
    }

    @Test func associateDirectoryAlsoKeysTheSymlinkResolvedPath() async throws {
        let url = freshFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // base/physical/repo on disk, registered through base/link → base/physical.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("physical/repo"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("link"),
            withDestinationURL: base.appendingPathComponent("physical")
        )
        let logicalRoot = base.appendingPathComponent("link/repo").path
        let project = SupermuxProject(name: "a", rootPath: logicalRoot)
        let store = SupermuxProjectStore(fileURL: url)
        try await store.save(SupermuxProjectsFile(version: 3, projects: [project]))
        let model = makeModel(store: store)
        await model.loadIfNeeded()

        model.associateDirectory(logicalRoot, with: project.id)

        // Both spellings are keyed so a lookup by the physical path (live PWD
        // reports may carry it) still finds the durable link.
        let logicalKey = SupermuxProjectMatcher.normalizedDirectory(logicalRoot)
        let resolvedKey = SupermuxProjectMatcher.resolvedDirectory(logicalRoot)
        #expect(resolvedKey != logicalKey)
        #expect(model.directoryAssociations[logicalKey] == project.id)
        #expect(model.directoryAssociations[resolvedKey] == project.id)

        let associations = SupermuxWorkspaceAssociationStore(persistence: model)
        let physicalRoot = base.appendingPathComponent("physical/repo").path
        #expect(associations.projectId(forWorkspace: UUID(), directory: physicalRoot, in: [project]) == project.id)
    }

    @Test func removingProjectPrunesItsLinks() async throws {
        let url = freshFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let project = SupermuxProject(name: "a", rootPath: "/repos/a")
        let store = SupermuxProjectStore(fileURL: url)
        try await store.save(SupermuxProjectsFile(
            version: 3,
            projects: [project],
            directoryAssociations: ["/repos/a": project.id]
        ))
        let model = makeModel(store: store)
        await model.loadIfNeeded()
        #expect(model.directoryAssociations == ["/repos/a": project.id])

        model.removeProject(id: project.id)

        #expect(model.directoryAssociations.isEmpty)
        let persisted = await waitForPersistedAssociationCount(store, expected: 0)
        #expect((persisted ?? [:]).isEmpty)
    }
}
