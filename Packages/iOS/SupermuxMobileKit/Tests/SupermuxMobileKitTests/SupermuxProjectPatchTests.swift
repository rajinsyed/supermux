import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// The typed patch encoder for `mobile.supermux.project.update`: every wire
/// key must match m2-f3's committed patch shape exactly — present keys only,
/// explicit `NSNull` clears a nullable field, arrays travel whole.
@Suite struct SupermuxProjectPatchTests {
    @Test func emptyPatchEncodesToAnEmptyObjectAndReportsEmpty() {
        let patch = SupermuxProjectPatch()
        #expect(patch.isEmpty)
        #expect(patch.wireObject.isEmpty)
    }

    @Test func everyFieldUsesItsExactWireKey() {
        var patch = SupermuxProjectPatch()
        patch.name = "Renamed"
        patch.colorHex = .set("#3b82f6")
        patch.iconSymbol = .set("folder")
        patch.defaultBranch = .set("main")
        patch.worktreesDirName = ".trees"
        patch.runCommands = ["bun run dev"]
        patch.setupCommands = ["bun install"]
        patch.teardownCommands = ["./teardown.sh"]
        patch.actions = [
            SupermuxProjectActionDTO(
                id: "6F9B2E44-6F70-4E86-8D6F-111111111111",
                name: "Build",
                command: "make build",
                iconSymbol: "hammer"
            ),
        ]
        #expect(!patch.isEmpty)
        let expected: NSDictionary = [
            "name": "Renamed",
            "color_hex": "#3b82f6",
            "icon_symbol": "folder",
            "default_branch": "main",
            "worktrees_dir_name": ".trees",
            "run_commands": ["bun run dev"],
            "setup_commands": ["bun install"],
            "teardown_commands": ["./teardown.sh"],
            "actions": [
                [
                    "id": "6F9B2E44-6F70-4E86-8D6F-111111111111",
                    "name": "Build",
                    "command": "make build",
                    "icon_symbol": "hammer",
                ],
            ],
        ]
        #expect(patch.wireObject as NSDictionary == expected)
    }

    @Test func clearSendsExplicitNull() {
        var patch = SupermuxProjectPatch()
        patch.colorHex = .clear
        patch.iconSymbol = .clear
        patch.defaultBranch = .clear
        let object = patch.wireObject
        #expect(object.count == 3)
        #expect(object["color_hex"] is NSNull)
        #expect(object["icon_symbol"] is NSNull)
        #expect(object["default_branch"] is NSNull)
    }

    @Test func absentFieldsNeverAppearOnTheWire() {
        var patch = SupermuxProjectPatch()
        patch.name = "Only Name"
        #expect(patch.wireObject as NSDictionary == ["name": "Only Name"] as NSDictionary)
    }

    @Test func actionEncodingOmitsAbsentOptionalsAndPreservesKindAndURL() {
        var patch = SupermuxProjectPatch()
        patch.actions = [
            SupermuxProjectActionDTO(
                id: "6F9B2E44-6F70-4E86-8D6F-222222222222",
                name: "Deploy",
                command: "make deploy",
                iconSymbol: nil,
                kind: "command",
                url: nil
            ),
        ]
        let actions = patch.wireObject["actions"] as? [[String: Any]]
        #expect(actions?.count == 1)
        #expect(actions?.first as NSDictionary? == [
            "id": "6F9B2E44-6F70-4E86-8D6F-222222222222",
            "name": "Deploy",
            "command": "make deploy",
            "kind": "command",
        ] as NSDictionary)
    }

    @Test func emptyArraysStillTravelWholeToClearServerState() {
        var patch = SupermuxProjectPatch()
        patch.runCommands = []
        patch.actions = []
        let object = patch.wireObject
        #expect((object["run_commands"] as? [String]) == [])
        #expect((object["actions"] as? [[String: Any]])?.isEmpty == true)
    }
}

/// The preset patch encoder for `mobile.supermux.preset.update`.
@Suite struct SupermuxPresetPatchTests {
    @Test func emptyPatchEncodesToAnEmptyObject() {
        let patch = SupermuxPresetPatch()
        #expect(patch.isEmpty)
        #expect(patch.wireObject.isEmpty)
    }

    @Test func everyFieldUsesItsExactWireKey() {
        var patch = SupermuxPresetPatch()
        patch.name = "Claude"
        patch.command = "claude --resume"
        patch.iconSymbol = .set("sparkles")
        patch.colorHex = .set("#a855f7")
        #expect(patch.wireObject as NSDictionary == [
            "name": "Claude",
            "command": "claude --resume",
            "icon_symbol": "sparkles",
            "color_hex": "#a855f7",
        ] as NSDictionary)
    }

    @Test func clearSendsExplicitNull() {
        var patch = SupermuxPresetPatch()
        patch.colorHex = .clear
        let object = patch.wireObject
        #expect(object.count == 1)
        #expect(object["color_hex"] is NSNull)
    }
}
