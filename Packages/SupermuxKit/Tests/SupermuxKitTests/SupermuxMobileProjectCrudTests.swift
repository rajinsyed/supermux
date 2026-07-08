import Foundation
import Testing
@testable import SupermuxKit

/// CRUD tests for the mobile project write flow (validation contract
/// RPC-PROJ-02), driven through the exact ``SupermuxProjectsModel`` calls and
/// package types the `mobile.supermux.project.*` handlers use: create imports
/// a repo-shipped `config.json` exactly like the desktop add path and the
/// result DTO carries the read-only marker (`config_path`); update applies
/// only the patch's present keys and replaces arrays whole; delete drops the
/// project and its durable associations. Each step is verified against the
/// projects file on disk, decoded from raw bytes (never the store's cache).
@MainActor
struct SupermuxMobileProjectCrudTests {
    private let configJSON = """
    {
      "setup": ["bun install"],
      "teardown": ["./teardown.sh"],
      "run": ["bun run dev"],
      "actions": [{ "name": "Build", "command": "make build", "icon": "build" }]
    }
    """

    // MARK: - Fixtures

    private func makeTempDirectory(_ prefix: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Writes the config fixture into `root` under `folder` (`.supermux` or
    /// `.superset`).
    private func writeConfig(under root: String, folder: String) throws {
        let dir = (root as NSString).appendingPathComponent(folder)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try configJSON.write(
            toFile: (dir as NSString).appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeModel(storeDir: String) -> (model: SupermuxProjectsModel, fileURL: URL) {
        let fileURL = URL(fileURLWithPath: storeDir).appendingPathComponent("projects.json")
        let model = SupermuxProjectsModel(
            store: SupermuxProjectStore(fileURL: fileURL),
            worktreeService: SupermuxGitWorktreeService()
        )
        return (model, fileURL)
    }

    /// Decodes the projects document from the raw on-disk bytes, bypassing
    /// every in-memory cache, so assertions prove real persistence.
    private func decodeDiskFile(_ url: URL) -> SupermuxProjectsFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SupermuxProjectsFile.self, from: data)
    }

    /// Polls the on-disk document until `predicate` holds (the model's persist
    /// chain is fire-and-forget), returning the matching document or the last
    /// read on timeout.
    private func waitForDisk(
        _ url: URL,
        until predicate: (SupermuxProjectsFile) -> Bool
    ) async -> SupermuxProjectsFile? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let file = decodeDiskFile(url), predicate(file) { return file }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return decodeDiskFile(url)
    }

    // MARK: - RPC-PROJ-02: create imports config.json (desktop-identical)

    @Test func createImportsSupermuxConfigPersistsAndMarksConfigManaged() async throws {
        let projectRoot = try makeTempDirectory("supermux-mobile-project-crud-root")
        defer { cleanUp(projectRoot) }
        let storeDir = try makeTempDirectory("supermux-mobile-project-crud-store")
        defer { cleanUp(storeDir) }
        try writeConfig(under: projectRoot, folder: ".supermux")
        let (model, fileURL) = makeModel(storeDir: storeDir)
        await model.loadIfNeeded()

        // The exact call `mobile.supermux.project.create` makes.
        let project = await model.addProject(rootPath: projectRoot)

        // Config-managed fields imported by the model, exactly like desktop add.
        #expect(project.setupCommands == ["bun install"])
        #expect(project.teardownCommands == ["./teardown.sh"])
        #expect(project.runCommands == ["bun run dev"])
        #expect(project.actions.map(\.name) == ["Build"])
        #expect(project.actions.first?.iconSymbol == "hammer")

        // The read-only marker mirrors the desktop editor's config detection.
        #expect(SupermuxMobileProjectConfigMarker.managedRelativePath(projectRoot: projectRoot) == ".supermux/config.json")

        // The wire result carries the imported fields plus the marker.
        let payload = try SupermuxMobileProjectsPayloadBuilder().projectPayload(project: project)
        let dto = try #require(payload["project"] as? [String: Any])
        #expect(dto["id"] as? String == project.id.uuidString)
        #expect(dto["run_commands"] as? [String] == ["bun run dev"])
        #expect(dto["setup_commands"] as? [String] == ["bun install"])
        #expect(dto["teardown_commands"] as? [String] == ["./teardown.sh"])
        #expect(dto["config_path"] as? String == ".supermux/config.json")

        // The projects file on disk reflects the create, imported fields included.
        let disk = await waitForDisk(fileURL) { file in
            file.projects.contains { $0.id == project.id && $0.runCommands == ["bun run dev"] }
        }
        let persisted = try #require(disk?.projects.first { $0.id == project.id })
        #expect(persisted.setupCommands == ["bun install"])
        #expect(persisted.actions.map(\.name) == ["Build"])
    }

    @Test func createImportsSupersetConfigForDropInCompatibility() async throws {
        let projectRoot = try makeTempDirectory("supermux-mobile-project-crud-superset")
        defer { cleanUp(projectRoot) }
        let storeDir = try makeTempDirectory("supermux-mobile-project-crud-store2")
        defer { cleanUp(storeDir) }
        try writeConfig(under: projectRoot, folder: ".superset")
        let (model, _) = makeModel(storeDir: storeDir)
        await model.loadIfNeeded()

        let project = await model.addProject(rootPath: projectRoot)

        #expect(project.runCommands == ["bun run dev"])
        #expect(SupermuxMobileProjectConfigMarker.managedRelativePath(projectRoot: projectRoot) == ".superset/config.json")
    }

    @Test func plainFolderCreateHasNoConfigMarker() async throws {
        let projectRoot = try makeTempDirectory("supermux-mobile-project-crud-plain")
        defer { cleanUp(projectRoot) }
        let storeDir = try makeTempDirectory("supermux-mobile-project-crud-store3")
        defer { cleanUp(storeDir) }
        let (model, _) = makeModel(storeDir: storeDir)
        await model.loadIfNeeded()

        let project = await model.addProject(rootPath: projectRoot)

        #expect(SupermuxMobileProjectConfigMarker.managedRelativePath(projectRoot: projectRoot) == nil)
        let payload = try SupermuxMobileProjectsPayloadBuilder().projectPayload(project: project)
        let dto = try #require(payload["project"] as? [String: Any])
        #expect(dto["config_path"] == nil)
    }

    // MARK: - RPC-PROJ-02: update patch semantics

    @Test func updateAppliesOnlyPresentKeysAndReplacesArraysWhole() async throws {
        let projectRoot = try makeTempDirectory("supermux-mobile-project-crud-update")
        defer { cleanUp(projectRoot) }
        let storeDir = try makeTempDirectory("supermux-mobile-project-crud-store4")
        defer { cleanUp(storeDir) }
        let (model, fileURL) = makeModel(storeDir: storeDir)
        await model.loadIfNeeded()
        var seeded = await model.addProject(rootPath: projectRoot)
        seeded.colorHex = "#112233"
        seeded.runCommands = ["old run", "old run 2"]
        seeded.setupCommands = ["old setup"]
        model.updateProject(seeded)

        let actionID = UUID()
        // The exact parse + apply the `mobile.supermux.project.update` handler runs.
        let patch = try SupermuxMobileProjectPatch(wire: [
            "name": "Renamed",
            "run_commands": ["bun run dev"],
            "actions": [[
                "id": actionID.uuidString,
                "name": "Deploy",
                "command": "make deploy",
                "icon_symbol": "paperplane",
            ]],
        ])
        let updated = try patch.applied(to: seeded, isConfigManaged: false)
        model.updateProject(updated)

        // Present keys applied; arrays replaced whole.
        #expect(updated.name == "Renamed")
        #expect(updated.runCommands == ["bun run dev"])
        #expect(updated.actions == [
            SupermuxProjectAction(id: actionID, name: "Deploy", command: "make deploy", iconSymbol: "paperplane"),
        ])
        // Absent keys untouched.
        #expect(updated.colorHex == "#112233")
        #expect(updated.setupCommands == ["old setup"])
        #expect(updated.rootPath == seeded.rootPath)
        #expect(updated.id == seeded.id)
        #expect(updated.createdAt == seeded.createdAt)

        // The projects file on disk reflects the update.
        let disk = await waitForDisk(fileURL) { file in
            file.projects.contains { $0.id == seeded.id && $0.name == "Renamed" }
        }
        let persisted = try #require(disk?.projects.first { $0.id == seeded.id })
        #expect(persisted.runCommands == ["bun run dev"])
        #expect(persisted.colorHex == "#112233")
        #expect(persisted.actions.map(\.name) == ["Deploy"])
    }

    @Test func patchClearsNullableFieldsWithExplicitNull() throws {
        var project = SupermuxProject(name: "Demo", rootPath: "/tmp/demo")
        project.colorHex = "#112233"
        project.iconSymbol = "sparkle"
        project.defaultBranch = "main"

        let patch = try SupermuxMobileProjectPatch(wire: [
            "color_hex": NSNull(),
            "icon_symbol": NSNull(),
            "default_branch": NSNull(),
        ])
        let updated = try patch.applied(to: project, isConfigManaged: false)

        #expect(updated.colorHex == nil)
        #expect(updated.iconSymbol == nil)
        #expect(updated.defaultBranch == nil)
        #expect(updated.name == "Demo")
    }

    @Test func patchRejectsUnknownImmutableAndMalformedKeys() {
        func parseError(_ wire: [String: Any]) -> SupermuxMobilePatchError? {
            do {
                _ = try SupermuxMobileProjectPatch(wire: wire)
                return nil
            } catch let error as SupermuxMobilePatchError {
                return error
            } catch {
                return nil
            }
        }
        #expect(parseError(["shiny_new_key": 1]) == .unknownKey("shiny_new_key"))
        #expect(parseError(["id": UUID().uuidString]) == .immutableKey("id"))
        #expect(parseError(["root_path": "/elsewhere"]) == .immutableKey("root_path"))
        #expect(parseError(["created_at": 123]) == .immutableKey("created_at"))
        #expect(parseError(["last_opened_at": 123]) == .immutableKey("last_opened_at"))
        #expect(parseError(["has_custom_icon": true]) == .immutableKey("has_custom_icon"))
        #expect(parseError(["custom_icon_path": "/x.png"]) == .immutableKey("custom_icon_path"))
        #expect(parseError(["config_path": ".supermux/config.json"]) == .immutableKey("config_path"))
        #expect(parseError(["name": ""]) == .emptyValue(key: "name"))
        #expect(parseError(["name": NSNull()]) == .invalidValue(key: "name"))
        #expect(parseError(["run_commands": "not-an-array"]) == .invalidValue(key: "run_commands"))
        #expect(parseError(["run_commands": [1, 2]]) == .invalidValue(key: "run_commands"))
        #expect(parseError(["worktrees_dir_name": "a/b"]) == .invalidValue(key: "worktrees_dir_name"))
        #expect(parseError(["worktrees_dir_name": ".."]) == .invalidValue(key: "worktrees_dir_name"))
        #expect(parseError(["actions": [["id": "not-a-uuid", "name": "x", "command": "y"]]]) == .invalidValue(key: "actions"))
        #expect(parseError(["actions": [["id": UUID().uuidString, "name": "x", "command": "y", "kind": "open_url"]]]) == .invalidValue(key: "actions"))
    }

    @Test func patchRejectsConfigManagedKeysWhenConfigOwnsThem() throws {
        let project = SupermuxProject(name: "Demo", rootPath: "/tmp/demo")
        let managedPatches: [[String: Any]] = [
            ["run_commands": ["x"]],
            ["setup_commands": ["x"]],
            ["teardown_commands": ["x"]],
            ["actions": [[String: Any]]()],
        ]
        for wire in managedPatches {
            let patch = try SupermuxMobileProjectPatch(wire: wire)
            var thrown: SupermuxMobilePatchError?
            do {
                _ = try patch.applied(to: project, isConfigManaged: true)
            } catch let error as SupermuxMobilePatchError {
                thrown = error
            }
            let key = try #require(wire.keys.first)
            #expect(thrown == .configManagedKey(key), "config-managed '\(key)' must be rejected")
            // The same patch applies fine when no config manages the project.
            _ = try patch.applied(to: project, isConfigManaged: false)
        }
        // User-owned fields stay editable on a config-managed project.
        let cosmetic = try SupermuxMobileProjectPatch(wire: ["name": "New", "color_hex": "#445566"])
        let updated = try cosmetic.applied(to: project, isConfigManaged: true)
        #expect(updated.name == "New")
        #expect(updated.colorHex == "#445566")
    }

    // MARK: - RPC-PROJ-02: delete

    @Test func deleteRemovesProjectAndItsAssociationsFromDisk() async throws {
        let projectRoot = try makeTempDirectory("supermux-mobile-project-crud-delete")
        defer { cleanUp(projectRoot) }
        let storeDir = try makeTempDirectory("supermux-mobile-project-crud-store5")
        defer { cleanUp(storeDir) }
        let (model, fileURL) = makeModel(storeDir: storeDir)
        await model.loadIfNeeded()
        let project = await model.addProject(rootPath: projectRoot)
        model.associateDirectory(projectRoot, with: project.id)
        _ = await waitForDisk(fileURL) { file in
            file.projects.contains { $0.id == project.id }
                && file.directoryAssociations?.values.contains(project.id) == true
        }

        // The exact call `mobile.supermux.project.delete` makes.
        model.removeProject(id: project.id)

        #expect(model.projects.isEmpty)
        let disk = await waitForDisk(fileURL) { file in
            !file.projects.contains { $0.id == project.id }
        }
        let file = try #require(disk)
        #expect(!file.projects.contains { $0.id == project.id })
        #expect(file.directoryAssociations?.values.contains(project.id) != true)
    }
}
