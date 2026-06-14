import Foundation
import Testing
@testable import SupermuxKit

/// Tests for `SupermuxProjectConfig` decoding, the on-disk loader, and the
/// mapping of a config into a `SupermuxProject` (the auto-import path).
struct SupermuxProjectConfigTests {
    // MARK: - Fixtures

    /// Creates a unique temp directory and returns its path.
    private func makeTempDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// Writes `json` to `<root>/<relative>`, creating intermediate directories.
    private func write(_ json: String, to relative: String, under root: String) throws {
        let path = (root as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Decoding

    @Test func decodesFullConfig() throws {
        let json = """
        {
          "setup": ["bun install\\ncp \\"$SUPERSET_ROOT_PATH/.env\\" .env\\nexit"],
          "teardown": ["./.superset/teardown.sh"],
          "run": ["cd apps/desktop\\nbun dev"],
          "actions": [
            { "id": "0090e980-9407-4d2a-b672-9010953c91c0", "name": "Open github", "command": "open https://example.com", "icon": "deploy" }
          ]
        }
        """
        let config = try JSONDecoder().decode(SupermuxProjectConfig.self, from: Data(json.utf8))
        #expect(config.setup == ["bun install\ncp \"$SUPERSET_ROOT_PATH/.env\" .env\nexit"])
        #expect(config.teardown == ["./.superset/teardown.sh"])
        #expect(config.run == ["cd apps/desktop\nbun dev"])
        #expect(config.actions.count == 1)
        #expect(config.actions.first?.name == "Open github")
        #expect(config.actions.first?.icon == "deploy")
    }

    @Test func decodesPartialConfigWithMissingArrays() throws {
        let config = try JSONDecoder().decode(
            SupermuxProjectConfig.self,
            from: Data(#"{ "setup": ["bun install"] }"#.utf8)
        )
        #expect(config.setup == ["bun install"])
        #expect(config.teardown.isEmpty)
        #expect(config.run.isEmpty)
        #expect(config.actions.isEmpty)
    }

    // MARK: - Loader

    @Test func loaderPrefersSupermuxOverSuperset() throws {
        let root = try makeTempDirectory()
        defer { cleanUp(root) }
        try write(#"{ "run": ["superset"] }"#, to: ".superset/config.json", under: root)
        try write(#"{ "run": ["supermux"] }"#, to: ".supermux/config.json", under: root)

        let config = try #require(SupermuxProjectConfigLoader().load(projectRoot: root))
        #expect(config.run == ["supermux"])
    }

    @Test func loaderReadsSupersetWhenSupermuxAbsent() throws {
        let root = try makeTempDirectory()
        defer { cleanUp(root) }
        try write(#"{ "run": ["from-superset"] }"#, to: ".superset/config.json", under: root)

        let config = try #require(SupermuxProjectConfigLoader().load(projectRoot: root))
        #expect(config.run == ["from-superset"])
    }

    @Test func loaderReturnsNilWhenNoConfig() throws {
        let root = try makeTempDirectory()
        defer { cleanUp(root) }
        #expect(SupermuxProjectConfigLoader().load(projectRoot: root) == nil)
        #expect(SupermuxProjectConfigLoader().resolvedRelativePath(projectRoot: root) == nil)
    }

    @Test func resolvedRelativePathReportsTheFoundFile() throws {
        let root = try makeTempDirectory()
        defer { cleanUp(root) }
        try write(#"{}"#, to: ".superset/config.json", under: root)
        #expect(SupermuxProjectConfigLoader().resolvedRelativePath(projectRoot: root) == ".superset/config.json")
    }

    // MARK: - Applying to a project

    @Test func applyingOverwritesConfigManagedFieldsOnly() {
        var project = SupermuxProject(name: "Demo", rootPath: "/tmp/demo", colorHex: "#ff0000")
        project.runCommands = ["old run"]
        project.setupCommands = ["old setup"]
        project.actions = [SupermuxProjectAction(name: "Old", command: "old")]

        let config = SupermuxProjectConfig(
            setup: ["bun install"],
            teardown: ["cleanup.sh"],
            run: ["bun dev"],
            actions: [.init(name: "Build", command: "make", icon: "build")]
        )
        let applied = project.applying(config)

        // Config-managed fields replaced…
        #expect(applied.setupCommands == ["bun install"])
        #expect(applied.teardownCommands == ["cleanup.sh"])
        #expect(applied.runCommands == ["bun dev"])
        #expect(applied.actions.map(\.name) == ["Build"])
        #expect(applied.actions.first?.iconSymbol == "hammer") // "build" → SF Symbol
        // …user-owned fields untouched.
        #expect(applied.name == "Demo")
        #expect(applied.colorHex == "#ff0000")
    }

    @Test func applyingTrimsAndDropsBlankCommands() {
        let config = SupermuxProjectConfig(setup: ["  bun install  ", "", "   "])
        let applied = SupermuxProject(name: "X", rootPath: "/tmp/x").applying(config)
        #expect(applied.setupCommands == ["bun install"])
    }

    @Test func applyingIsIdempotent() {
        // Re-importing an unchanged config must produce an equal project, so the
        // model's change-detection never churns persistence across launches.
        let config = SupermuxProjectConfig(
            run: ["bun dev"],
            actions: [.init(id: "open-editor", name: "Edit", command: "code .", icon: "edit")]
        )
        let project = SupermuxProject(name: "X", rootPath: "/tmp/x")
        let once = project.applying(config)
        let twice = once.applying(config)
        #expect(once == twice)
    }

    // MARK: - Action mapping

    @Test func actionKeepsValidUUIDAndMapsIcon() {
        let action = SupermuxProjectConfig.Action(
            id: "0090e980-9407-4d2a-b672-9010953c91c0",
            name: "Deploy",
            command: "deploy.sh",
            icon: "deploy"
        )
        let mapped = try? #require(action.toProjectAction())
        #expect(mapped?.id == UUID(uuidString: "0090e980-9407-4d2a-b672-9010953c91c0"))
        #expect(mapped?.iconSymbol == "paperplane")
    }

    @Test func actionWithSlugIdDerivesStableUUID() {
        let action = SupermuxProjectConfig.Action(id: "open-github", name: "GH", command: "open x")
        let first = action.toProjectAction()?.id
        let second = action.toProjectAction()?.id
        #expect(first != nil)
        #expect(first == second) // deterministic across imports
    }

    @Test func actionWithoutNameOrCommandIsDropped() {
        #expect(SupermuxProjectConfig.Action(name: "", command: "x").toProjectAction() == nil)
        #expect(SupermuxProjectConfig.Action(name: "x", command: "  ").toProjectAction() == nil)
    }

    @Test func unknownIconPassesThroughAndBlankFallsToNil() {
        #expect(SupermuxProjectConfig.sfSymbol(forIcon: "hammer.fill") == "hammer.fill")
        #expect(SupermuxProjectConfig.sfSymbol(forIcon: "bolt") == "bolt")
        #expect(SupermuxProjectConfig.sfSymbol(forIcon: "  ") == nil)
        #expect(SupermuxProjectConfig.sfSymbol(forIcon: nil) == nil)
    }
}
