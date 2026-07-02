import Foundation
import Testing
@testable import SupermuxKit

/// Behavior tests for `SupermuxProjectsModel`: the shared reorder path behind
/// sidebar drag-reorder and the Move Up / Move Down menu, single-flight
/// loading, concurrent-add dedupe, semantic persistence that must not clobber
/// a concurrent app instance's writes, and error surfacing.
///
/// The model is `@MainActor`, so the suite is too. Each test seeds a throwaway
/// store on disk.
@MainActor
struct SupermuxProjectsModelTests {
    /// A fresh, unique temp-directory URL (not created on disk).
    private func freshTempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    /// Polls until `condition` holds, yielding so the model's fire-and-forget
    /// persist chain can flush. Returns the final evaluation.
    private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    /// A project with a unique throwaway root path. The path need not exist;
    /// reorder never touches git, and worktree refresh fails gracefully to `[]`.
    private func sample(_ name: String) -> SupermuxProject {
        SupermuxProject(name: name, rootPath: "/tmp/supermux-\(name)-\(UUID().uuidString)")
    }

    /// Builds a model pre-seeded with `projects` persisted on disk and loaded.
    private func makeLoadedModel(
        projects: [SupermuxProject],
        fileURL: URL
    ) async throws -> SupermuxProjectsModel {
        let store = SupermuxProjectStore(fileURL: fileURL)
        try await store.save(SupermuxProjectsFile(
            version: SupermuxProjectsFile.currentVersion,
            projects: projects,
            isSectionCollapsed: false
        ))
        let model = SupermuxProjectsModel(
            store: store,
            worktreeService: SupermuxGitWorktreeService()
        )
        await model.loadIfNeeded()
        return model
    }

    @Test func moveProjectDownInsertsAfterTarget() async throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = sample("a"), b = sample("b"), c = sample("c")
        let model = try await makeLoadedModel(
            projects: [a, b, c],
            fileURL: dir.appendingPathComponent("projects.json")
        )

        // Drag "a" down onto "c": it should land immediately after "c".
        model.moveProject(a.id, over: c.id)
        #expect(model.projects.map(\.id) == [b.id, c.id, a.id])
    }

    @Test func moveProjectUpInsertsBeforeTarget() async throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = sample("a"), b = sample("b"), c = sample("c")
        let model = try await makeLoadedModel(
            projects: [a, b, c],
            fileURL: dir.appendingPathComponent("projects.json")
        )

        // Drag "c" up onto "a": it should land immediately before "a".
        model.moveProject(c.id, over: a.id)
        #expect(model.projects.map(\.id) == [c.id, a.id, b.id])
    }

    @Test func moveProjectOverAdjacentNeighborSwapsThePair() async throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = sample("a"), b = sample("b"), c = sample("c")
        let model = try await makeLoadedModel(
            projects: [a, b, c],
            fileURL: dir.appendingPathComponent("projects.json")
        )

        // The Move Up menu action moves a project over its immediate neighbor.
        model.moveProject(b.id, over: a.id)
        #expect(model.projects.map(\.id) == [b.id, a.id, c.id])
    }

    @Test func moveProjectIsNoOpForSameOrUnknownIds() async throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = sample("a"), b = sample("b"), c = sample("c")
        let model = try await makeLoadedModel(
            projects: [a, b, c],
            fileURL: dir.appendingPathComponent("projects.json")
        )
        let original = model.projects.map(\.id)

        model.moveProject(a.id, over: a.id)        // same id
        model.moveProject(UUID(), over: a.id)      // unknown dragged id
        model.moveProject(a.id, over: UUID())      // unknown target id
        #expect(model.projects.map(\.id) == original)
    }

    // MARK: - Cross-instance persistence (shared projects file)

    @Test func noteOpenedDoesNotClobberAProjectAddedByAnotherInstance() async throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("projects.json")
        let opened = sample("opened")
        let store = SupermuxProjectStore(fileURL: fileURL)
        try await store.save(SupermuxProjectsFile(
            version: SupermuxProjectsFile.currentVersion,
            projects: [opened]
        ))
        let model = SupermuxProjectsModel(store: store, worktreeService: SupermuxGitWorktreeService())
        await model.loadIfNeeded()

        // Another running build (fresh store instance, same file) registers a
        // project this model has never seen.
        let addedElsewhere = sample("added-elsewhere")
        let otherInstance = SupermuxProjectStore(fileURL: fileURL)
        try await otherInstance.update { $0.projects.append(addedElsewhere) }

        // A mere recency stamp from this instance must apply semantically to
        // the freshly-read document — not overwrite it with this instance's
        // stale in-memory array, which would delete the other build's project.
        model.noteOpened(id: opened.id)

        // The tail of the persist chain also folds disk truth back into memory.
        #expect(await waitUntil { model.projects.map(\.id) == [opened.id, addedElsewhere.id] })
        let persisted = await store.load()
        #expect(persisted.projects.map(\.id) == [opened.id, addedElsewhere.id])
        #expect(persisted.projects.first?.lastOpenedAt != nil)
    }

    // MARK: - Concurrency

    @Test func concurrentAddsOfTheSameFolderRegisterOnce() async throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = SupermuxProjectStore(fileURL: dir.appendingPathComponent("projects.json"))
        let model = SupermuxProjectsModel(store: store, worktreeService: SupermuxGitWorktreeService())
        await model.loadIfNeeded()

        // Both adds pass the entry dedupe before either resumes from the git
        // probes (main-actor reentrancy); the post-await re-check must collapse
        // them to one record.
        async let first = model.addProject(rootPath: folder.path)
        async let second = model.addProject(rootPath: folder.path)
        let (a, b) = await (first, second)

        #expect(a.id == b.id)
        #expect(model.projects.count == 1)
    }

    @Test func concurrentLoadIfNeededCallsShareOneLoad() async throws {
        let dir = freshTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SupermuxProjectStore(fileURL: dir.appendingPathComponent("projects.json"))
        try await store.save(SupermuxProjectsFile(
            version: SupermuxProjectsFile.currentVersion,
            projects: [sample("a")]
        ))
        let model = SupermuxProjectsModel(store: store, worktreeService: SupermuxGitWorktreeService())

        // Two windows mounting the Projects section at once must not run the
        // full load body (config import + git worktree listing per project) twice.
        async let firstLoad: Void = model.loadIfNeeded()
        async let secondLoad: Void = model.loadIfNeeded()
        _ = await (firstLoad, secondLoad)

        #expect(model.loadRunCount == 1)
        #expect(model.projects.count == 1)
        await model.loadIfNeeded()
        #expect(model.loadRunCount == 1)
    }

    // MARK: - Error surfacing

    @Test func successfulPersistClearsLastError() async throws {
        let dir = freshTempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A regular file where the store's parent directory should go makes
        // every write fail until it is removed.
        let blocker = dir.appendingPathComponent("blocked")
        #expect(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
        let store = SupermuxProjectStore(fileURL: blocker.appendingPathComponent("projects.json"))
        let model = SupermuxProjectsModel(store: store, worktreeService: SupermuxGitWorktreeService())

        await model.loadIfNeeded()  // the preset-seed persist fails on the blocker
        #expect(await waitUntil { model.lastError != nil })

        try FileManager.default.removeItem(at: blocker)
        model.addPreset(SupermuxTerminalPreset(name: "x", command: "x"))
        #expect(await waitUntil { model.lastError == nil })
    }

    @Test func corruptFileSurfacesALoadFailureNotice() async throws {
        let dir = freshTempDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("projects.json")
        try Data("not json at all".utf8).write(to: fileURL)
        let store = SupermuxProjectStore(fileURL: fileURL)
        let model = SupermuxProjectsModel(store: store, worktreeService: SupermuxGitWorktreeService())

        await model.loadIfNeeded()

        // The user must be told their list was reset (with the backup path)
        // instead of silently seeing zero projects.
        #expect(model.loadFailureNotice != nil)
        #expect(model.projects.isEmpty)
    }
}
