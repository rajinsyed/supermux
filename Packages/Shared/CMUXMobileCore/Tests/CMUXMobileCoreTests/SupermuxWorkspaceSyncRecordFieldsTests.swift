import Foundation
import Testing

@testable import CMUXMobileCore

/// Fork coverage for the additive supermux fields on ``WorkspaceSyncRecord``
/// (`supermux-mobile-workspace-fields`). Mobile state sync v2 becomes
/// authoritative on any Mac that answers `mobile.sync.fetch`, so these four
/// fields must survive the record wire round-trip or project nesting, the
/// agent-activity dot, the branch subtitle, and the PR badge silently vanish on
/// the phone. Records from an upstream cmux Mac carry none of them and must
/// still decode.
struct SupermuxWorkspaceSyncRecordFieldsTests {
    private func makeRecord(
        supermuxProjectID: String? = nil,
        supermuxActivity: String? = nil,
        supermuxBranch: String? = nil,
        supermuxPullRequest: WorkspaceSyncRecord.SupermuxPullRequest? = nil
    ) -> WorkspaceSyncRecord {
        WorkspaceSyncRecord(
            id: "ws-1",
            windowID: "win-1",
            title: "build",
            currentDirectory: "/repo",
            isSelected: false,
            isPinned: false,
            groupID: nil,
            preview: nil,
            previewAt: nil,
            lastActivityAt: 1_700_000_000,
            hasUnread: false,
            sortIndex: 0,
            terminals: [],
            supermuxProjectID: supermuxProjectID,
            supermuxActivity: supermuxActivity,
            supermuxBranch: supermuxBranch,
            supermuxPullRequest: supermuxPullRequest
        )
    }

    private var populatedRecord: WorkspaceSyncRecord {
        makeRecord(
            supermuxProjectID: "9E2B7F1C-0000-4000-8000-000000000001",
            supermuxActivity: "needs_input",
            supermuxBranch: "feature/mobile-sync",
            supermuxPullRequest: WorkspaceSyncRecord.SupermuxPullRequest(
                number: 4321,
                state: "open",
                url: "https://github.com/manaflow-ai/cmux/pull/4321",
                isStale: true
            )
        )
    }

    @Test func supermuxFieldsUseTheLegacyListPayloadWireKeys() throws {
        let object = try MobileSyncFrameCoder().jsonObject(from: populatedRecord)

        #expect(object["supermux_project_id"] as? String == "9E2B7F1C-0000-4000-8000-000000000001")
        #expect(object["supermux_activity"] as? String == "needs_input")
        #expect(object["supermux_branch"] as? String == "feature/mobile-sync")
        let pullRequest = object["supermux_pull_request"] as? [String: Any]
        #expect(pullRequest?["number"] as? Int == 4321)
        #expect(pullRequest?["state"] as? String == "open")
        #expect(pullRequest?["url"] as? String == "https://github.com/manaflow-ai/cmux/pull/4321")
        #expect(pullRequest?["is_stale"] as? Bool == true)
    }

    @Test func supermuxFieldsRoundTripThroughTheRecordWire() throws {
        let coder = MobileSyncFrameCoder()
        let decoded = try coder.decode(
            WorkspaceSyncRecord.self,
            fromJSONObject: coder.jsonObject(from: populatedRecord)
        )

        // Equality is what drives the Mac-side diff, so the whole record must
        // survive, not just the individual fields.
        #expect(decoded == populatedRecord)
        #expect(decoded.supermuxProjectID == "9E2B7F1C-0000-4000-8000-000000000001")
        #expect(decoded.supermuxActivity == "needs_input")
        #expect(decoded.supermuxBranch == "feature/mobile-sync")
        #expect(decoded.supermuxPullRequest?.number == 4321)
        #expect(decoded.supermuxPullRequest?.state == "open")
        #expect(decoded.supermuxPullRequest?.url == "https://github.com/manaflow-ai/cmux/pull/4321")
        #expect(decoded.supermuxPullRequest?.isStale == true)
    }

    @Test func upstreamMacRecordWithoutSupermuxFieldsDecodesWithThemAllNil() throws {
        let decoded = try MobileSyncFrameCoder().decode(
            WorkspaceSyncRecord.self,
            fromJSONString: """
            {
              "id": "ws-upstream",
              "window_id": "win-1",
              "title": "upstream",
              "current_directory": null,
              "is_selected": false,
              "is_pinned": false,
              "group_id": null,
              "preview": null,
              "preview_at": null,
              "last_activity_at": 1,
              "has_unread": false,
              "sort_index": 0,
              "terminals": []
            }
            """
        )

        #expect(decoded.id == "ws-upstream")
        #expect(decoded.supermuxProjectID == nil)
        #expect(decoded.supermuxActivity == nil)
        #expect(decoded.supermuxBranch == nil)
        #expect(decoded.supermuxPullRequest == nil)
    }

    @Test func recordWithoutSupermuxFieldsEmitsNoSupermuxKeys() throws {
        let object = try MobileSyncFrameCoder().jsonObject(from: makeRecord())

        #expect(object["supermux_project_id"] == nil)
        #expect(object["supermux_activity"] == nil)
        #expect(object["supermux_branch"] == nil)
        #expect(object["supermux_pull_request"] == nil)
    }

    @Test func malformedSupermuxFieldsDegradeToNilInsteadOfFailingTheRecord() throws {
        let decoded = try MobileSyncFrameCoder().decode(
            WorkspaceSyncRecord.self,
            fromJSONString: """
            {
              "id": "ws-malformed",
              "window_id": "win-1",
              "title": "malformed",
              "current_directory": null,
              "is_selected": false,
              "is_pinned": false,
              "group_id": null,
              "preview": null,
              "preview_at": null,
              "last_activity_at": 1,
              "has_unread": false,
              "sort_index": 0,
              "terminals": [],
              "supermux_project_id": 17,
              "supermux_activity": ["working"],
              "supermux_branch": false,
              "supermux_pull_request": {"number": "not-a-number", "state": 9, "is_stale": "yes"}
            }
            """
        )

        // A garbled extension must never fail the record: a thrown decode here
        // would gap the client's mirror and stall the whole list.
        #expect(decoded.id == "ws-malformed")
        #expect(decoded.supermuxProjectID == nil)
        #expect(decoded.supermuxActivity == nil)
        #expect(decoded.supermuxBranch == nil)
        #expect(decoded.supermuxPullRequest?.number == nil)
        #expect(decoded.supermuxPullRequest?.state == nil)
        #expect(decoded.supermuxPullRequest?.isStale == nil)
    }

    @Test func nonObjectPullRequestDegradesToEmptyFieldsInsteadOfFailing() throws {
        let decoded = try MobileSyncFrameCoder().decode(
            WorkspaceSyncRecord.self,
            fromJSONString: """
            {
              "id": "ws-pr-string",
              "window_id": "win-1",
              "title": "pr string",
              "current_directory": null,
              "is_selected": false,
              "is_pinned": false,
              "group_id": null,
              "preview": null,
              "preview_at": null,
              "last_activity_at": 1,
              "has_unread": false,
              "sort_index": 0,
              "terminals": [],
              "supermux_pull_request": "nope"
            }
            """
        )

        #expect(decoded.id == "ws-pr-string")
        #expect(decoded.supermuxPullRequest?.number == nil)
        #expect(decoded.supermuxPullRequest?.url == nil)
    }

    @Test func supermuxFieldChangesAreVisibleToTheDiffsEqualityCheck() {
        let base = makeRecord(supermuxProjectID: "p-1", supermuxActivity: "working")

        #expect(base != makeRecord(supermuxProjectID: "p-1", supermuxActivity: "ready"))
        #expect(base != makeRecord(supermuxProjectID: "p-2", supermuxActivity: "working"))
        #expect(
            makeRecord(supermuxBranch: "main")
                != makeRecord(supermuxBranch: "release")
        )
        #expect(
            makeRecord(supermuxPullRequest: .init(number: 1))
                != makeRecord(supermuxPullRequest: .init(number: 2))
        )
        #expect(base == makeRecord(supermuxProjectID: "p-1", supermuxActivity: "working"))
    }
}
