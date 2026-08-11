import CmuxMobileShellModel
@testable import SupermuxMobileUI
import Testing

@Suite struct SupermuxMobilePaneUnreadPresentationTests {
    private let panelID = "22222222-2222-2222-2222-222222222222"

    @Test func matchingUnreadPaneShowsTheRing() {
        let presentation = SupermuxMobilePaneUnreadPresentation(
            workspace: workspace(unreadPanelIDs: [panelID]),
            panelID: panelID
        )

        #expect(presentation.supportsPaneUnreadState)
        #expect(presentation.showsRing)
    }

    @Test func siblingPaneDoesNotShowTheRing() {
        let presentation = SupermuxMobilePaneUnreadPresentation(
            workspace: workspace(unreadPanelIDs: [
                "33333333-3333-3333-3333-333333333333",
            ]),
            panelID: panelID
        )

        #expect(presentation.supportsPaneUnreadState)
        #expect(!presentation.showsRing)
    }

    @Test func absentFieldMeansHostDoesNotSupportPaneUnreadState() {
        let presentation = SupermuxMobilePaneUnreadPresentation(
            workspace: workspace(unreadPanelIDs: nil),
            panelID: panelID
        )

        #expect(!presentation.supportsPaneUnreadState)
        #expect(!presentation.showsRing)
    }

    @Test func emptyArrayMeansSupportedHostWithNoUnreadPane() {
        let presentation = SupermuxMobilePaneUnreadPresentation(
            workspace: workspace(unreadPanelIDs: []),
            panelID: panelID
        )

        #expect(presentation.supportsPaneUnreadState)
        #expect(!presentation.showsRing)
    }

    @Test func missingOrBlankVisiblePaneFailsClosed() {
        let workspace = workspace(unreadPanelIDs: [panelID])

        #expect(!SupermuxMobilePaneUnreadPresentation(
            workspace: workspace,
            panelID: nil
        ).showsRing)
        #expect(!SupermuxMobilePaneUnreadPresentation(
            workspace: workspace,
            panelID: "  "
        ).showsRing)
    }

    @Test func wireIdentifiersAreComparedAfterWhitespaceNormalization() {
        let presentation = SupermuxMobilePaneUnreadPresentation(
            workspace: workspace(unreadPanelIDs: ["  \(panelID)  "]),
            panelID: " \(panelID) "
        )

        #expect(presentation.showsRing)
    }

    @Test func paneStateNotWorkspaceVisibilityDrivesTheRing() {
        var workspace = workspace(unreadPanelIDs: [panelID])
        workspace.hasUnread = false

        #expect(SupermuxMobilePaneUnreadPresentation(
            workspace: workspace,
            panelID: panelID
        ).showsRing)
    }

    @Test func exactPaneCapabilityDisablesTheLegacyOpenReadReceipt() {
        #expect(workspace(unreadPanelIDs: nil, hasUnread: true)
            .supermuxShouldUseLegacyWorkspaceReadReceiptOnOpen)
        #expect(!workspace(unreadPanelIDs: [], hasUnread: true)
            .supermuxShouldUseLegacyWorkspaceReadReceiptOnOpen)
        #expect(!workspace(unreadPanelIDs: [panelID], hasUnread: true)
            .supermuxShouldUseLegacyWorkspaceReadReceiptOnOpen)
        #expect(!workspace(unreadPanelIDs: nil, hasUnread: false)
            .supermuxShouldUseLegacyWorkspaceReadReceiptOnOpen)
    }

    @Test func ringStyleMatchesTheMacPaneRing() {
        let style = SupermuxMobileUnreadPaneRingStyle.macOSParity

        #expect(style.inset == 2)
        #expect(style.cornerRadius == 6)
        #expect(style.lineWidth == 2.5)
        #expect(style.glowOpacity == 0.35)
        #expect(style.glowRadius == 3)
    }

    private func workspace(
        unreadPanelIDs: [String]?,
        hasUnread: Bool = false
    ) -> MobileWorkspacePreview {
        var workspace = MobileWorkspacePreview(
            id: .init(rawValue: "11111111-1111-1111-1111-111111111111"),
            name: "Workspace",
            terminals: []
        )
        workspace.hasUnread = hasUnread
        workspace.supermuxUnreadPanelIDs = unreadPanelIDs
        return workspace
    }
}
