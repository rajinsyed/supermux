import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// Typed decoding of the write-RPC results exactly as
/// `SupermuxMobileHost+Projects.swift` / `+PresetsActions.swift` emit them,
/// plus the request values' exact §2 wire methods.
@Suite struct SupermuxProjectWriteWireTests {
    private func decode<Response: Decodable>(_ type: Response.Type, from json: String) throws -> Response {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func projectWriteResultDecodesTheProjectEnvelope() throws {
        let response = try decode(SupermuxProjectWriteResponse.self, from: """
        {
          "project": {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "alpha",
            "root_path": "/Users/dev/alpha",
            "worktrees_dir_name": ".worktrees",
            "run_commands": ["bun run dev"],
            "has_custom_icon": false,
            "config_path": ".supermux/config.json",
            "created_at": 1751970000
          }
        }
        """)
        #expect(response.project.name == "alpha")
        #expect(response.project.configPath == ".supermux/config.json")
        #expect(response.project.runCommands == ["bun run dev"])
    }

    @Test func deleteAndCollapseResultsDecodeLeniently() throws {
        let deleted = try decode(SupermuxProjectDeleteResponse.self, from: """
        {"removed": true, "project_id": "11111111-1111-1111-1111-111111111111"}
        """)
        #expect(deleted.removed == true)
        #expect(deleted.projectId == "11111111-1111-1111-1111-111111111111")

        let collapsed = try decode(SupermuxSectionCollapsedResponse.self, from: """
        {"section_collapsed": true}
        """)
        #expect(collapsed.sectionCollapsed == true)

        // Old/partial hosts: empty objects still decode.
        _ = try decode(SupermuxProjectDeleteResponse.self, from: "{}")
        _ = try decode(SupermuxSectionCollapsedResponse.self, from: "{}")
    }

    @Test func presetResultsDecodeThePresetEnvelope() throws {
        let response = try decode(SupermuxPresetWriteResponse.self, from: """
        {
          "preset": {
            "id": "33333333-3333-3333-3333-333333333333",
            "name": "Claude",
            "command": "claude",
            "icon_symbol": "sparkles",
            "color_hex": "#a855f7"
          }
        }
        """)
        #expect(response.preset.name == "Claude")
        #expect(response.preset.colorHex == "#a855f7")

        let deleted = try decode(SupermuxPresetDeleteResponse.self, from: """
        {"removed": true, "preset_id": "33333333-3333-3333-3333-333333333333"}
        """)
        #expect(deleted.removed == true)
        #expect(deleted.presetId == "33333333-3333-3333-3333-333333333333")
    }

    @Test func requestValuesCarryTheExactSection2MethodStrings() {
        #expect(SupermuxProjectCreateRequest(rootPath: "/x").wireMethod
            == "mobile.supermux.project.create")
        #expect(SupermuxProjectUpdateRequest(projectID: "p", patch: SupermuxProjectPatch()).wireMethod
            == "mobile.supermux.project.update")
        #expect(SupermuxProjectDeleteRequest(projectID: "p").wireMethod
            == "mobile.supermux.project.delete")
        #expect(SupermuxProjectsSetSectionCollapsedRequest(collapsed: true).wireMethod
            == "mobile.supermux.projects.set_section_collapsed")
        #expect(SupermuxPresetCreateRequest(name: "n", command: "c").wireMethod
            == "mobile.supermux.preset.create")
        #expect(SupermuxPresetUpdateRequest(presetID: "p", patch: SupermuxPresetPatch()).wireMethod
            == "mobile.supermux.preset.update")
        #expect(SupermuxPresetDeleteRequest(presetID: "p").wireMethod
            == "mobile.supermux.preset.delete")
    }
}
