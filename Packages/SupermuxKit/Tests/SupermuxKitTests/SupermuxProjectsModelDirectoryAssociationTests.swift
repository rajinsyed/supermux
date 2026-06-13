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
