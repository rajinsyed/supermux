import Foundation
import Testing
@testable import SupermuxKit

/// Tests that `SupermuxProjectsModel` auto-imports a repo-shipped `config.json`
/// into a project's setup/teardown/run/actions, on both add and load.
@MainActor
struct SupermuxProjectsModelConfigTests {
    private let configJSON = """
    {
      "setup": ["bun install"],
      "teardown": ["cleanup.sh"],
      "run": ["bun dev"],
      "actions": [{ "name": "Build", "command": "make", "icon": "build" }]
    }
    """

    private func makeTempDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-model-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// Writes a `.superset/config.json` into `root`.
    private func writeConfig(under root: String) throws {
        let dir = (root as NSString).appendingPathComponent(".superset")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try configJSON.write(
            toFile: (dir as NSString).appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func makeModel(storeDir: String) -> SupermuxProjectsModel {
        let storeURL = URL(fileURLWithPath: storeDir).appendingPathComponent("projects.json")
        return SupermuxProjectsModel(
            store: SupermuxProjectStore(fileURL: storeURL),
            worktreeService: SupermuxGitWorktreeService()
        )
    }

    @Test func addProjectImportsConfig() async throws {
        let projectRoot = try makeTempDirectory()
        defer { cleanUp(projectRoot) }
        let storeDir = try makeTempDirectory()
        defer { cleanUp(storeDir) }
        try writeConfig(under: projectRoot)

        let model = makeModel(storeDir: storeDir)
        await model.loadIfNeeded()
        let project = await model.addProject(rootPath: projectRoot)

        #expect(project.setupCommands == ["bun install"])
        #expect(project.teardownCommands == ["cleanup.sh"])
        #expect(project.runCommands == ["bun dev"])
        #expect(project.actions.map(\.name) == ["Build"])
        #expect(project.actions.first?.iconSymbol == "hammer")
    }

    @Test func loadReimportsConfigForPersistedProjects() async throws {
        let projectRoot = try makeTempDirectory()
        defer { cleanUp(projectRoot) }
        let storeDir = try makeTempDirectory()
        defer { cleanUp(storeDir) }
        try writeConfig(under: projectRoot)

        // Persist a project that has NONE of the config-managed fields yet.
        let storeURL = URL(fileURLWithPath: storeDir).appendingPathComponent("projects.json")
        let store = SupermuxProjectStore(fileURL: storeURL)
        try await store.save(SupermuxProjectsFile(
            version: SupermuxProjectsFile.currentVersion,
            projects: [SupermuxProject(name: "Demo", rootPath: projectRoot)]
        ))

        // A fresh model loading that store must pick the config up on load.
        let model = SupermuxProjectsModel(store: store, worktreeService: SupermuxGitWorktreeService())
        await model.loadIfNeeded()

        let project = try #require(model.projects.first)
        #expect(project.runCommands == ["bun dev"])
        #expect(project.setupCommands == ["bun install"])
        #expect(project.actions.map(\.name) == ["Build"])
    }
}
