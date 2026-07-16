import Foundation
import Testing
@testable import SupermuxMobileCore

@Suite struct SupermuxProjectDTOCodingTests {
    private let coding = WireCodingTestSupport()

    private var fullProject: SupermuxProjectDTO {
        SupermuxProjectDTO(
            id: "6F1B2C3D-0000-0000-0000-000000000001",
            name: "supermux",
            rootPath: "/Users/dev/supermux",
            colorHex: "#f97316",
            iconSymbol: "sparkle",
            hasCustomIcon: true,
            defaultBranch: "main",
            worktreesDirName: ".worktrees",
            runCommands: ["bun dev"],
            setupCommands: ["bun install"],
            teardownCommands: ["docker compose down"],
            actions: [
                SupermuxProjectActionDTO(
                    id: "6F1B2C3D-0000-0000-0000-000000000002",
                    name: "Open in Editor",
                    command: "cursor .",
                    iconSymbol: "pencil",
                    kind: "command",
                    url: nil
                ),
            ],
            createdAt: 1_900_000_000,
            lastOpenedAt: 1_900_000_100,
            configPath: ".supermux/config.json"
        )
    }

    @Test func projectRoundTrips() throws {
        let copy = try coding.roundTrip(fullProject)
        #expect(copy == fullProject)
    }

    @Test func projectEncodesSnakeCaseKeys() throws {
        let keys = try coding.encodedKeys(of: fullProject)
        #expect(keys == [
            "id", "name", "root_path", "color_hex", "icon_symbol",
            "has_custom_icon", "default_branch", "worktrees_dir_name",
            "run_commands", "setup_commands", "teardown_commands", "actions",
            "created_at", "last_opened_at", "config_path",
        ])
    }

    @Test func projectDecodesWithOnlyEssentialFields() throws {
        let json = """
        {"id": "p-1", "name": "demo", "root_path": "/tmp/demo"}
        """
        let project = try coding.decode(SupermuxProjectDTO.self, from: json)
        #expect(project.id == "p-1")
        #expect(project.name == "demo")
        #expect(project.rootPath == "/tmp/demo")
        #expect(project.colorHex == nil)
        #expect(project.actions == nil)
        #expect(project.createdAt == nil)
        #expect(project.configPath == nil)
    }

    @Test func projectUnknownFieldTolerance() throws {
        let json = """
        {
          "id": "p-1",
          "name": "demo",
          "root_path": "/tmp/demo",
          "color_hex": "#112233",
          "future_field": 42,
          "future_object": {"nested": ["deep", 1]},
          "actions": [
            {"id": "a-1", "name": "run", "command": "make", "future_flag": true}
          ]
        }
        """
        let project = try coding.decode(SupermuxProjectDTO.self, from: json)
        #expect(project.id == "p-1")
        #expect(project.colorHex == "#112233")
        #expect(project.actions?.first?.command == "make")
    }

    @Test func terminalPresetRoundTrips() throws {
        let preset = SupermuxTerminalPresetDTO(
            id: "preset-1",
            name: "claude",
            command: "claude",
            iconSymbol: "sparkle",
            colorHex: "#f97316"
        )
        #expect(try coding.roundTrip(preset) == preset)
        let keys = try coding.encodedKeys(of: preset)
        #expect(keys == ["id", "name", "command", "icon_symbol", "color_hex"])
    }

    @Test func terminalPresetUnknownFieldTolerance() throws {
        let json = """
        {"id": "preset-1", "name": "codex", "command": "codex", "shiny_new_toggle": true}
        """
        let preset = try coding.decode(SupermuxTerminalPresetDTO.self, from: json)
        #expect(preset.name == "codex")
        #expect(preset.iconSymbol == nil)
    }

    @Test func projectActionRoundTrips() throws {
        let action = SupermuxProjectActionDTO(
            id: "a-1",
            name: "Open PR",
            command: "gh pr view --web",
            iconSymbol: "arrow.up.right",
            kind: "open_url",
            url: "https://example.com/pr/1"
        )
        #expect(try coding.roundTrip(action) == action)
        let keys = try coding.encodedKeys(of: action)
        #expect(keys == ["id", "name", "command", "icon_symbol", "kind", "url"])
    }

    @Test func projectActionUnknownFieldTolerance() throws {
        let json = """
        {"id": "a-1", "name": "run", "command": "make", "extra": {"a": 1}}
        """
        let action = try coding.decode(SupermuxProjectActionDTO.self, from: json)
        #expect(action.id == "a-1")
        #expect(action.kind == nil)
        #expect(action.url == nil)
    }
}
