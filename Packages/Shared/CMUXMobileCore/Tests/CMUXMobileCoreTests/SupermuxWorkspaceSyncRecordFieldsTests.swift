import Foundation
import Testing

@testable import CMUXMobileCore

/// Fork coverage for the additive supermux workspace metadata and focused-panel
/// fields on ``WorkspaceSyncRecord``. Mobile state sync v2 becomes
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
        supermuxPullRequest: WorkspaceSyncRecord.SupermuxPullRequest? = nil,
        supermuxUnreadCount: Int? = nil,
        supermuxUnreadPanelIDs: [String]? = nil,
        // SUPERMUX:begin supermux-mobile-selection-sync
        focusedPanel: MobileWorkspaceFocusedPanel? = nil
        // SUPERMUX:end supermux-mobile-selection-sync
    ) -> WorkspaceSyncRecord {
        WorkspaceSyncRecord(
            id: "ws-1",
            windowID: "win-1",
            title: "build",
            currentDirectory: "/repo",
            isSelected: false,
            // SUPERMUX:begin supermux-mobile-selection-sync
            focusedPanel: focusedPanel,
            // SUPERMUX:end supermux-mobile-selection-sync
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
            supermuxPullRequest: supermuxPullRequest,
            supermuxUnreadCount: supermuxUnreadCount,
            supermuxUnreadPanelIDs: supermuxUnreadPanelIDs
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
        // SUPERMUX:begin supermux-mobile-selection-sync
        #expect(decoded.focusedPanel == nil)
        // SUPERMUX:end supermux-mobile-selection-sync
        #expect(decoded.supermuxProjectID == nil)
        #expect(decoded.supermuxActivity == nil)
        #expect(decoded.supermuxBranch == nil)
        #expect(decoded.supermuxPullRequest == nil)
        // An upstream Mac reports `has_unread` but never the fork's exact count
        // or pane state, so the phone keeps both legacy fallbacks available.
        #expect(decoded.supermuxUnreadCount == nil)
        #expect(decoded.supermuxUnreadPanelIDs == nil)
    }

    @Test func recordWithoutSupermuxFieldsEmitsNoSupermuxKeys() throws {
        let object = try MobileSyncFrameCoder().jsonObject(from: makeRecord())

        #expect(object["supermux_project_id"] == nil)
        #expect(object["supermux_activity"] == nil)
        #expect(object["supermux_branch"] == nil)
        #expect(object["supermux_pull_request"] == nil)
        #expect(object["supermux_unread_count"] == nil)
        #expect(object["supermux_unread_panel_ids"] == nil)
    }

    // SUPERMUX:begin supermux-mobile-selection-sync
    @Test func focusedPanelUsesTheGenericWireShapeAndRoundTrips() throws {
        let focusedPanel = MobileWorkspaceFocusedPanel(
            panelID: "browser-1",
            kind: MobileWorkspaceFocusedPanel.browserKind
        )
        let record = makeRecord(focusedPanel: focusedPanel)
        let coder = MobileSyncFrameCoder()
        let object = try coder.jsonObject(from: record)
        let wirePanel = try #require(object["focused_panel"] as? [String: Any])
        #expect(wirePanel["panel_id"] as? String == "browser-1")
        #expect(wirePanel["kind"] as? String == "browser")

        let decoded = try coder.decode(
            WorkspaceSyncRecord.self,
            fromJSONObject: object
        )
        #expect(decoded.focusedPanel == focusedPanel)
        #expect(decoded == record)
    }

    @Test func malformedFocusedPanelDegradesToNilInsteadOfFailingTheRecord() throws {
        let decoded = try MobileSyncFrameCoder().decode(
            WorkspaceSyncRecord.self,
            fromJSONString: """
            {
              "id": "ws-bad-focus",
              "window_id": "win-1",
              "title": "bad focus",
              "current_directory": null,
              "is_selected": true,
              "focused_panel": {"panel_id": 17, "kind": ["browser"]},
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

        #expect(decoded.id == "ws-bad-focus")
        #expect(decoded.focusedPanel == nil)
    }

    @Test func focusedPanelChangesAreVisibleToTheDiffsEqualityCheck() {
        let browser = MobileWorkspaceFocusedPanel(
            panelID: "panel-1",
            kind: MobileWorkspaceFocusedPanel.browserKind
        )
        let simulator = MobileWorkspaceFocusedPanel(
            panelID: "panel-2",
            kind: MobileWorkspaceFocusedPanel.simulatorKind
        )
        #expect(makeRecord(focusedPanel: browser) != makeRecord(focusedPanel: simulator))
        #expect(makeRecord(focusedPanel: browser) == makeRecord(focusedPanel: browser))
    }
    // SUPERMUX:end supermux-mobile-selection-sync

    @Test func theUnreadCountSurvivesTheRecordRoundTrip() throws {
        // The count travels for EVERY workspace, not just project-associated
        // ones, so it is asserted on a record carrying no other fork field.
        let coder = MobileSyncFrameCoder()
        let object = try coder.jsonObject(from: makeRecord(supermuxUnreadCount: 12))
        #expect(object["supermux_unread_count"] as? Int == 12)

        let decoded = try coder.decode(
            WorkspaceSyncRecord.self,
            fromJSONString: """
            {
              "id": "ws-counted",
              "window_id": "win-1",
              "title": "counted",
              "current_directory": null,
              "is_selected": false,
              "is_pinned": false,
              "group_id": null,
              "preview": null,
              "preview_at": null,
              "last_activity_at": 1,
              "has_unread": true,
              "sort_index": 0,
              "terminals": [],
              "supermux_unread_count": 12
            }
            """
        )
        #expect(decoded.supermuxUnreadCount == 12)
    }

    @Test func aMalformedUnreadCountDegradesToNilInsteadOfFailingTheRecord() throws {
        let decoded = try MobileSyncFrameCoder().decode(
            WorkspaceSyncRecord.self,
            fromJSONString: """
            {
              "id": "ws-bad-count",
              "window_id": "win-1",
              "title": "bad count",
              "current_directory": null,
              "is_selected": false,
              "is_pinned": false,
              "group_id": null,
              "preview": null,
              "preview_at": null,
              "last_activity_at": 1,
              "has_unread": true,
              "sort_index": 0,
              "terminals": [],
              "supermux_unread_count": "seven"
            }
            """
        )

        #expect(decoded.id == "ws-bad-count")
        #expect(decoded.hasUnread)
        #expect(decoded.supermuxUnreadCount == nil)
    }

    @Test func anUnreadCountChangeIsVisibleToTheDiffsEqualityCheck() {
        // Without this the badge would keep showing a stale numeral: the sync
        // mirror skips records it considers unchanged, so a count that moves
        // from 1 to 2 with nothing else changing must compare unequal.
        #expect(makeRecord(supermuxUnreadCount: 1) != makeRecord(supermuxUnreadCount: 2))
        #expect(makeRecord(supermuxUnreadCount: nil) != makeRecord(supermuxUnreadCount: 0))
    }

    @Test func unreadPanelIDsPreserveCapabilityAndRoundTrip() throws {
        let panelIDs = ["panel-a", "panel-b"]
        let record = makeRecord(supermuxUnreadPanelIDs: panelIDs)
        let coder = MobileSyncFrameCoder()
        let object = try coder.jsonObject(from: record)

        #expect(object["supermux_unread_panel_ids"] as? [String] == panelIDs)
        #expect(try coder.decode(
            WorkspaceSyncRecord.self,
            fromJSONObject: object
        ) == record)
        #expect(makeRecord(supermuxUnreadPanelIDs: nil) != makeRecord(supermuxUnreadPanelIDs: []))
        #expect(makeRecord(supermuxUnreadPanelIDs: []) != record)
    }

    @Test func malformedUnreadPanelIDsDegradeToUnsupported() throws {
        let decoded = try MobileSyncFrameCoder().decode(
            WorkspaceSyncRecord.self,
            fromJSONString: """
            {
              "id": "ws-bad-panels",
              "window_id": "win-1",
              "title": "bad panels",
              "current_directory": null,
              "is_selected": false,
              "is_pinned": false,
              "group_id": null,
              "preview": null,
              "preview_at": null,
              "last_activity_at": 1,
              "has_unread": true,
              "sort_index": 0,
              "terminals": [],
              "supermux_unread_panel_ids": ["panel-a", 7]
            }
            """
        )

        #expect(decoded.id == "ws-bad-panels")
        #expect(decoded.supermuxUnreadPanelIDs == nil)
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
