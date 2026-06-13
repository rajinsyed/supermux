import Foundation
import Testing
@testable import SupermuxKit

/// Behavior tests for `SupermuxProjectsModel.moveProject(_:over:)`, the shared
/// reorder path behind sidebar drag-reorder and the Move Up / Move Down menu.
///
/// The model is `@MainActor`, so the suite is too. Each test seeds a throwaway
/// store on disk, loads it, then asserts the in-memory order after a move.
@MainActor
struct SupermuxProjectsModelTests {
    /// A fresh, unique temp-directory URL (not created on disk).
    private func freshTempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
}
