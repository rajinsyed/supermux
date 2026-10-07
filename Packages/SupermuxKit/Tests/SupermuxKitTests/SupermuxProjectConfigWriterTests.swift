import Foundation
import Testing
@testable import SupermuxKit

/// Tests for `SupermuxProjectConfigWriter`, which saves the Edit Project
/// sheet's run/setup/teardown/actions into the fork-native
/// `.supermux/config.json`.
///
/// Each test pins one way the save could go wrong:
/// - the edit never reaches disk, or lands in superset's `.superset/config.json`;
/// - a field cleared in the editor falls back to superset's value on re-import;
/// - keys Supermux does not own are dropped from an existing file;
/// - a hand-edited file that is not valid JSON gets silently replaced;
/// - a missing project root is created instead of reported;
/// - the saved values re-import differently, so the record churns after Save.
struct SupermuxProjectConfigWriterTests {
    // MARK: - Fixtures

    private func makeTempDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("supermux-config-writer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func write(_ text: String, to relative: String, under root: String) throws {
        let path = (root as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func read(_ relative: String, under root: String) -> String? {
        try? String(contentsOfFile: (root as NSString).appendingPathComponent(relative), encoding: .utf8)
    }

    private func cleanUp(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private let supersetJSON = #"{ "setup": ["bun install"], "run": ["bun dev"], "teardown": ["./down.sh"] }"#

    // MARK: - Where the edit lands

    @Test func writesSupermuxFileAndLeavesSupersetUntouched() throws {
        let root = try makeTempDirectory()
        defer { cleanUp(root) }
        try write(supersetJSON, to: ".superset/config.json", under: root)

        let edited = SupermuxProjectConfig(setup: ["bun install\nbun db:migrate"], run: ["bun dev"])
        try SupermuxProjectConfigWriter().write(edited, projectRoot: root)

        let loader = SupermuxProjectConfigLoader()
        #expect(loader.resolvedRelativePath(projectRoot: root) == ".supermux/config.json")
        #expect(loader.load(projectRoot: root)?.setup == ["bun install\nbun db:migrate"])
        #expect(read(".superset/config.json", under: root) == supersetJSON)
    }

    @Test func clearedFieldsShadowSupersetValues() throws {
        let root = try makeTempDirectory()
        defer { cleanUp(root) }
        try write(supersetJSON, to: ".superset/config.json", under: root)

        try SupermuxProjectConfigWriter().write(SupermuxProjectConfig(), projectRoot: root)

        let loaded = try #require(SupermuxProjectConfigLoader().load(projectRoot: root))
        #expect(loaded.setup.isEmpty)
        #expect(loaded.teardown.isEmpty)
        #expect(loaded.run.isEmpty)
        #expect(loaded.actions.isEmpty)
    }

    // MARK: - Existing .supermux/config.json

    @Test func preservesKeysSupermuxDoesNotOwn() throws {
        let root = try makeTempDirectory()
        defer { cleanUp(root) }
        try write(#"{ "run": ["old"], "futureKey": { "keep": true } }"#, to: ".supermux/config.json", under: root)

        try SupermuxProjectConfigWriter().write(SupermuxProjectConfig(run: ["new"]), projectRoot: root)

        let data = try #require(read(".supermux/config.json", under: root)?.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["futureKey"] as? [String: Any])?["keep"] as? Bool == true)
        #expect(object["run"] as? [String] == ["new"])
    }

    @Test func refusesToReplaceMalformedFile() throws {
        let root = try makeTempDirectory()
        defer { cleanUp(root) }
        let broken = #"{ "run": ["half-typed"#
        try write(broken, to: ".supermux/config.json", under: root)

        #expect(throws: (any Error).self) {
            try SupermuxProjectConfigWriter().write(SupermuxProjectConfig(run: ["new"]), projectRoot: root)
        }
        #expect(read(".supermux/config.json", under: root) == broken)
    }

    @Test func refusesToReplaceNonObjectJSON() throws {
        let root = try makeTempDirectory()
        defer { cleanUp(root) }
        try write("[]", to: ".supermux/config.json", under: root)

        #expect(throws: (any Error).self) {
            try SupermuxProjectConfigWriter().write(SupermuxProjectConfig(run: ["new"]), projectRoot: root)
        }
        #expect(read(".supermux/config.json", under: root) == "[]")
    }

    // MARK: - Project root

    @Test func throwsWhenProjectRootIsMissing() throws {
        let parent = try makeTempDirectory()
        defer { cleanUp(parent) }
        let root = (parent as NSString).appendingPathComponent("gone")

        #expect(throws: (any Error).self) {
            try SupermuxProjectConfigWriter().write(SupermuxProjectConfig(run: ["x"]), projectRoot: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root))
    }

    // MARK: - Round trip

    @Test func savedProjectReimportsUnchanged() throws {
        let root = try makeTempDirectory()
        defer { cleanUp(root) }
        try write(supersetJSON, to: ".superset/config.json", under: root)
        let project = SupermuxProject(
            name: "demo",
            rootPath: root,
            runCommands: ["bun dev", "bun worker"],
            setupCommands: ["bun install\ncp \"$SUPERSET_ROOT_PATH/.env\" .env"],
            teardownCommands: [],
            actions: [
                SupermuxProjectAction(name: "Deploy", command: "bun deploy", iconSymbol: "paperplane"),
                SupermuxProjectAction(name: "Logs", command: "tail -f log"),
            ]
        )

        try SupermuxProjectConfigWriter().write(SupermuxProjectConfig(project: project), projectRoot: root)

        let loaded = try #require(SupermuxProjectConfigLoader().load(projectRoot: root))
        #expect(project.applying(loaded) == project)
    }
}
