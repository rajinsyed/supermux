import CmuxMobileShellModel
import Foundation
import Testing

@testable import CmuxMobileRPC

/// PROTO-03: the additive supermux workspace-list fields must not disturb the
/// existing `workspace.list` wire contract.
///
/// A recorded PRE-mission payload (every field the Mac emitted before the
/// supermux fork's augmentation, and no `supermux_*` keys) must decode
/// through ``MobileSyncWorkspaceListResponse`` unchanged; a payload that DOES
/// carry `supermux_project_id` / `supermux_activity` must decode with the two
/// optional fields populated.
@Suite struct SupermuxWorkspaceListFieldsDecodeTests {
    /// A representative pre-mission `mobile.workspace.list` result: two
    /// workspaces (one grouped, with terminals and the full preview/unread
    /// field set; one minimal with nulls), one group section, and a
    /// created-workspace id. No supermux keys anywhere.
    private static let preMissionPayload = #"""
    {
      "workspaces": [
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "window_id": "22222222-2222-2222-2222-222222222222",
          "title": "api server",
          "current_directory": "/Users/dev/api",
          "is_selected": true,
          "is_pinned": true,
          "group_id": "33333333-3333-3333-3333-333333333333",
          "preview": "build finished",
          "preview_at": 1751932800.5,
          "last_activity_at": 1751932800.5,
          "has_unread": true,
          "terminals": [
            {
              "id": "44444444-4444-4444-4444-444444444444",
              "title": "zsh",
              "current_directory": "/Users/dev/api",
              "is_ready": true,
              "is_focused": true
            }
          ]
        },
        {
          "id": "55555555-5555-5555-5555-555555555555",
          "window_id": null,
          "title": "scratch",
          "current_directory": null,
          "is_selected": false,
          "is_pinned": false,
          "group_id": null,
          "preview": null,
          "preview_at": null,
          "last_activity_at": 1751932000,
          "has_unread": false,
          "terminals": []
        }
      ],
      "groups": [
        {
          "id": "33333333-3333-3333-3333-333333333333",
          "name": "backend",
          "is_collapsed": false,
          "is_pinned": true,
          "anchor_workspace_id": "11111111-1111-1111-1111-111111111111",
          "member_workspace_ids": ["11111111-1111-1111-1111-111111111111"]
        }
      ],
      "created_workspace_id": "55555555-5555-5555-5555-555555555555"
    }
    """#

    @Test func preMissionPayloadDecodesUnchangedWithNoSupermuxFields() throws {
        let response = try MobileSyncWorkspaceListResponse.decode(Data(Self.preMissionPayload.utf8))

        try #require(response.workspaces.count == 2)
        let first = response.workspaces[0]
        #expect(first.id == "11111111-1111-1111-1111-111111111111")
        #expect(first.windowID == "22222222-2222-2222-2222-222222222222")
        #expect(first.title == "api server")
        #expect(first.currentDirectory == "/Users/dev/api")
        #expect(first.isSelected)
        #expect(first.isPinned == true)
        #expect(first.groupID == "33333333-3333-3333-3333-333333333333")
        #expect(first.preview == "build finished")
        #expect(first.previewAt == 1751932800.5)
        #expect(first.lastActivityAt == 1751932800.5)
        #expect(first.hasUnread == true)
        try #require(first.terminals.count == 1)
        #expect(first.terminals[0].id == "44444444-4444-4444-4444-444444444444")
        #expect(first.terminals[0].title == "zsh")
        #expect(first.terminals[0].currentDirectory == "/Users/dev/api")
        #expect(first.terminals[0].isReady == true)
        #expect(first.terminals[0].isFocused)

        let second = response.workspaces[1]
        #expect(second.id == "55555555-5555-5555-5555-555555555555")
        #expect(second.windowID == nil)
        #expect(second.title == "scratch")
        #expect(second.currentDirectory == nil)
        #expect(!second.isSelected)
        #expect(second.terminals.isEmpty)

        try #require(response.groups.count == 1)
        #expect(response.groups[0].name == "backend")
        #expect(response.groups[0].anchorWorkspaceID == "11111111-1111-1111-1111-111111111111")
        #expect(response.createdWorkspaceID == "55555555-5555-5555-5555-555555555555")
        #expect(response.createdTerminalID == nil)

        // The new optional fields stay absent on a pre-mission payload.
        #expect(first.supermuxProjectID == nil)
        #expect(first.supermuxActivity == nil)
        #expect(second.supermuxProjectID == nil)
        #expect(second.supermuxActivity == nil)
        #expect(first.supermuxBranch == nil)
        #expect(first.supermuxPullRequest == nil)
        #expect(second.supermuxBranch == nil)
        #expect(second.supermuxPullRequest == nil)
    }

    @Test func payloadWithSupermuxFieldsPopulatesThem() throws {
        let payload = #"""
        {
          "workspaces": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "alpha main",
              "is_selected": false,
              "terminals": [],
              "supermux_project_id": "66666666-6666-6666-6666-666666666666",
              "supermux_activity": "needs_input"
            },
            {
              "id": "55555555-5555-5555-5555-555555555555",
              "title": "standalone",
              "is_selected": false,
              "terminals": []
            }
          ]
        }
        """#
        let response = try MobileSyncWorkspaceListResponse.decode(Data(payload.utf8))

        try #require(response.workspaces.count == 2)
        #expect(response.workspaces[0].supermuxProjectID == "66666666-6666-6666-6666-666666666666")
        #expect(response.workspaces[0].supermuxActivity == "needs_input")
        #expect(response.workspaces[1].supermuxProjectID == nil)
        #expect(response.workspaces[1].supermuxActivity == nil)
    }

    @Test func supermuxFieldsFlowIntoTheWorkspacePreviewMapping() throws {
        let payload = #"""
        {
          "workspaces": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "alpha main",
              "is_selected": false,
              "terminals": [],
              "supermux_project_id": "66666666-6666-6666-6666-666666666666",
              "supermux_activity": "working"
            }
          ]
        }
        """#
        let response = try MobileSyncWorkspaceListResponse.decode(Data(payload.utf8))
        let preview = try #require(response.workspaces.first.map(MobileWorkspacePreview.init(remote:)))
        #expect(preview.supermuxProjectID == "66666666-6666-6666-6666-666666666666")
        #expect(preview.supermuxActivity == "working")
    }

    // MARK: - m6-f2 sidebar-row parity fields (supermux_branch / supermux_pull_request)

    @Test func payloadWithBranchAndPullRequestPopulatesThem() throws {
        let payload = #"""
        {
          "workspaces": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "alpha main",
              "is_selected": false,
              "terminals": [],
              "supermux_project_id": "66666666-6666-6666-6666-666666666666",
              "supermux_branch": "feature/parity",
              "supermux_pull_request": {
                "number": 4321,
                "state": "merged",
                "url": "https://github.com/acme/alpha/pull/4321"
              }
            }
          ]
        }
        """#
        let response = try MobileSyncWorkspaceListResponse.decode(Data(payload.utf8))
        let workspace = try #require(response.workspaces.first)
        #expect(workspace.supermuxBranch == "feature/parity")
        let pullRequest = try #require(workspace.supermuxPullRequest)
        #expect(pullRequest.number == 4321)
        #expect(pullRequest.state == "merged")
        #expect(pullRequest.url == "https://github.com/acme/alpha/pull/4321")
    }

    @Test func pullRequestToleratesMissingOptionalAndUnknownKeys() throws {
        // A future Mac may add PR keys or omit state/url; decoding must
        // tolerate both. `is_stale` rides through for the badge dimming.
        let payload = #"""
        {
          "workspaces": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "alpha main",
              "is_selected": false,
              "terminals": [],
              "supermux_pull_request": {
                "number": 7,
                "title": "Add parity",
                "is_stale": true,
                "some_future_key": {"nested": 1}
              }
            }
          ]
        }
        """#
        let response = try MobileSyncWorkspaceListResponse.decode(Data(payload.utf8))
        let pullRequest = try #require(response.workspaces.first?.supermuxPullRequest)
        #expect(pullRequest.number == 7)
        #expect(pullRequest.state == nil)
        #expect(pullRequest.url == nil)
        #expect(pullRequest.isStale == true)
    }

    @Test func malformedPullRequestDegradesToNoBadgeWithoutFailingTheList() throws {
        // Lossy extension decoding (PROTO-03): a PR object with wrong-typed
        // fields — or one that is not an object at all — must never fail the
        // whole workspace-list decode; it degrades to nil fields ("no badge").
        let payload = #"""
        {
          "workspaces": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "wrong types",
              "is_selected": false,
              "terminals": [],
              "supermux_pull_request": {"number": "seven", "state": 3, "url": false, "is_stale": "yes"}
            },
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "title": "not an object",
              "is_selected": false,
              "terminals": [],
              "supermux_pull_request": "garbage"
            }
          ]
        }
        """#
        let response = try MobileSyncWorkspaceListResponse.decode(Data(payload.utf8))
        try #require(response.workspaces.count == 2)
        let wrongTypes = try #require(response.workspaces[0].supermuxPullRequest)
        #expect(wrongTypes.number == nil)
        #expect(wrongTypes.state == nil)
        #expect(wrongTypes.url == nil)
        #expect(wrongTypes.isStale == nil)
        let notAnObject = try #require(response.workspaces[1].supermuxPullRequest)
        #expect(notAnObject.number == nil)

        // The preview mapping drops the number-less badge entirely.
        let preview = MobileWorkspacePreview(remote: response.workspaces[0])
        #expect(preview.supermuxPullRequestNumber == nil)
    }

    @Test func branchAndPullRequestFlowIntoTheWorkspacePreviewMapping() throws {
        let payload = #"""
        {
          "workspaces": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "alpha main",
              "is_selected": false,
              "terminals": [],
              "supermux_project_id": "66666666-6666-6666-6666-666666666666",
              "supermux_branch": "fix/row-parity",
              "supermux_pull_request": {
                "number": 88,
                "state": "open",
                "url": "https://github.com/acme/alpha/pull/88"
              }
            },
            {
              "id": "55555555-5555-5555-5555-555555555555",
              "title": "standalone",
              "is_selected": false,
              "terminals": []
            }
          ]
        }
        """#
        let response = try MobileSyncWorkspaceListResponse.decode(Data(payload.utf8))
        try #require(response.workspaces.count == 2)
        let preview = MobileWorkspacePreview(remote: response.workspaces[0])
        #expect(preview.supermuxBranch == "fix/row-parity")
        #expect(preview.supermuxPullRequestNumber == 88)
        #expect(preview.supermuxPullRequestState == "open")
        #expect(preview.supermuxPullRequestURL == "https://github.com/acme/alpha/pull/88")
        let bare = MobileWorkspacePreview(remote: response.workspaces[1])
        #expect(bare.supermuxBranch == nil)
        #expect(bare.supermuxPullRequestNumber == nil)
        #expect(bare.supermuxPullRequestState == nil)
        #expect(bare.supermuxPullRequestURL == nil)
    }
}
