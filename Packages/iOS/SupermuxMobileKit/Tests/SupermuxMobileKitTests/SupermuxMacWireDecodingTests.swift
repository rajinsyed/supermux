import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
import Testing

/// Decoding tests against the EXACT wire shapes the Mac host emits
/// (`SupermuxMobileHost+Projects.swift`): `projects.list` results,
/// `project.icon` raw keys (`not_modified`/`etag`/`png_base64`), and event
/// envelope mapping.
@Suite struct SupermuxMacWireDecodingTests {
    @Test func projectsListResponseDecodesMacResultShape() throws {
        let json = Data("""
        {
          "projects": [
            {
              "id": "0A6E3E1B-8C1F-4E58-9C1D-2B5F0E7A9C11",
              "name": "Alpha",
              "root_path": "/Users/dev/alpha",
              "color_hex": "#3b82f6",
              "icon_symbol": "folder",
              "has_custom_icon": true
            }
          ],
          "section_collapsed": true
        }
        """.utf8)
        let response = try JSONDecoder().decode(SupermuxProjectsListResponse.self, from: json)
        #expect(response.projects.count == 1)
        #expect(response.projects.first?.name == "Alpha")
        #expect(response.projects.first?.rootPath == "/Users/dev/alpha")
        #expect(response.projects.first?.hasCustomIcon == true)
        #expect(response.sectionCollapsed == true)
    }

    @Test func projectsListResponseToleratesMissingAndUnknownFields() throws {
        let json = Data(#"{"future_field": {"x": 1}}"#.utf8)
        let response = try JSONDecoder().decode(SupermuxProjectsListResponse.self, from: json)
        #expect(response.projects.isEmpty)
        // Missing `presets` is NOT the same as an empty bar: it means the
        // host predates the m2-f5 read shape, and the phone must hide the
        // presets UI rather than show a bar that looks wrongly empty.
        #expect(response.presets == nil)
        #expect(response.sectionCollapsed == nil)
    }

    @Test func projectsListResponseDistinguishesAnEmptyPresetsBarFromNoPresetsField() throws {
        let json = Data(#"{"projects": [], "presets": []}"#.utf8)
        let response = try JSONDecoder().decode(SupermuxProjectsListResponse.self, from: json)
        #expect(response.presets == [])
    }

    @Test func projectsListResponseDecodesGlobalPresets() throws {
        let json = Data("""
        {
          "projects": [],
          "presets": [
            {
              "id": "44444444-4444-4444-4444-444444444444",
              "name": "claude",
              "command": "claude --resume",
              "icon_symbol": "sparkle",
              "color_hex": "#f97316"
            },
            {
              "id": "55555555-5555-5555-5555-555555555555",
              "name": "codex",
              "command": "codex"
            }
          ],
          "section_collapsed": false
        }
        """.utf8)
        let response = try JSONDecoder().decode(SupermuxProjectsListResponse.self, from: json)
        #expect(response.presets == [
            SupermuxTerminalPresetDTO(
                id: "44444444-4444-4444-4444-444444444444",
                name: "claude",
                command: "claude --resume",
                iconSymbol: "sparkle",
                colorHex: "#f97316"
            ),
            SupermuxTerminalPresetDTO(
                id: "55555555-5555-5555-5555-555555555555",
                name: "codex",
                command: "codex"
            ),
        ])
    }

    @Test func iconResponseDecodesFullIconResult() throws {
        let json = Data(#"{"not_modified": false, "etag": "abc123", "png_base64": "aGVsbG8="}"#.utf8)
        let response = try JSONDecoder().decode(SupermuxProjectIconResponse.self, from: json)
        #expect(response.notModified == false)
        #expect(response.etag == "abc123")
        #expect(response.pngBase64 == "aGVsbG8=")
        #expect(response.pngData == Data("hello".utf8))
    }

    @Test func iconResponseDecodesNotModifiedResult() throws {
        let json = Data(#"{"not_modified": true, "etag": "abc123"}"#.utf8)
        let response = try JSONDecoder().decode(SupermuxProjectIconResponse.self, from: json)
        #expect(response.notModified == true)
        #expect(response.etag == "abc123")
        #expect(response.pngBase64 == nil)
        #expect(response.pngData == nil)
    }

    @Test func iconResponseToleratesUnknownFields() throws {
        let json = Data(#"{"not_modified": true, "etag": "e", "format": "png", "extra": 7}"#.utf8)
        let response = try JSONDecoder().decode(SupermuxProjectIconResponse.self, from: json)
        #expect(response.notModified == true)
        #expect(response.etag == "e")
    }

    @Test func eventMapsKnownTopicWithoutPayload() {
        let event = SupermuxMobileEvent(topic: "supermux.projects.updated", payloadJSON: nil)
        #expect(event?.topic == .projectsUpdated)
        #expect(event?.workspaceID == nil)
    }

    @Test func eventMapsChangesTopicWorkspacePayload() {
        let payload = Data(#"{"workspace_id": "workspace:7", "future": true}"#.utf8)
        let event = SupermuxMobileEvent(topic: "supermux.changes.updated", payloadJSON: payload)
        #expect(event?.topic == .changesUpdated)
        #expect(event?.workspaceID == "workspace:7")
    }

    @Test func eventRejectsUnknownTopic() {
        let event = SupermuxMobileEvent(topic: "workspace.updated", payloadJSON: nil)
        #expect(event == nil)
    }

    @Test func eventToleratesMalformedPayload() {
        let event = SupermuxMobileEvent(topic: "supermux.changes.updated", payloadJSON: Data("not json".utf8))
        #expect(event?.topic == .changesUpdated)
        #expect(event?.workspaceID == nil)
    }
}
