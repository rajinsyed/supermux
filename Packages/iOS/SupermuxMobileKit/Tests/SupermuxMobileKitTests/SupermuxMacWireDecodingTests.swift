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
        #expect(response.sectionCollapsed == nil)
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
