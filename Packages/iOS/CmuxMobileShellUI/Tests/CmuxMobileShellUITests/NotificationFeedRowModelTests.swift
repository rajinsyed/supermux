import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

/// Behavior coverage for the presentation strings the projection now builds
/// off the main actor. These rules used to live inside the row body; they must
/// survive the move byte-for-byte.
@Suite struct NotificationFeedRowModelTests {
    @Test func workspaceMatchingIsCaseWhitespaceAndDiacriticInsensitive() {
        let model = NotificationFeedRowModel(item: item(
            title: "  Résumé   Review ",
            workspaceTitle: "resume review"
        ))

        // The headline is the workspace, and the title restates it once folded,
        // so nothing is left for the provenance line.
        #expect(model.presentation.headline == "resume review")
        #expect(model.presentation.provenance == nil)
        #expect(model.presentation.workspaceName == "resume review")
    }

    @Test func redundantBodyFallsBackToSubtitleThenNil() {
        let bodyMatchesTitle = NotificationFeedRowModel(item: item(
            title: "Build finished",
            subtitle: "Release pipeline",
            body: "build FINISHED"
        ))
        #expect(bodyMatchesTitle.presentation.contentPreview == "Release pipeline")

        let bothRedundant = NotificationFeedRowModel(item: item(
            title: "Build finished",
            subtitle: "Workspace",
            body: " Build finished "
        ))
        #expect(bothRedundant.presentation.contentPreview == nil)

        let distinctBody = NotificationFeedRowModel(item: item(
            title: "Build finished",
            body: "Artifacts uploaded to the release bucket."
        ))
        #expect(distinctBody.presentation.contentPreview == "Artifacts uploaded to the release bucket.")
    }

    /// The title is the headline only when there is no workspace to use, and
    /// otherwise moves to the provenance line rather than disappearing.
    @Test func headlineIsTheWorkspaceAndDemotesTheTitle() {
        let model = NotificationFeedRowModel(item: item(
            title: "Claude Code",
            workspaceTitle: "fix notifications"
        ))

        #expect(model.presentation.headline == "fix notifications")
        #expect(model.presentation.provenance == "Claude Code")
    }

    @Test func missingWorkspaceUsesFallbackAndBlankComputerUsesDeviceID() {
        let model = NotificationFeedRowModel(item: item(
            workspaceTitle: "   ",
            macDisplayName: " "
        ))

        // A blank workspace must not promote the "Unknown workspace" UI
        // placeholder into the headline and push the real title below it.
        #expect(model.presentation.headline == "Title")
        #expect(model.presentation.workspaceName == "Unknown workspace")
        #expect(model.presentation.computerName == "mac-a")
    }

    @Test func computerStatusTextReflectsConnectionState() {
        #expect(
            NotificationFeedRowModel(item: item(connectionStatus: .connected))
                .presentation.computerStatusText == "Mac"
        )
        #expect(
            NotificationFeedRowModel(item: item(connectionStatus: .reconnecting))
                .presentation.computerStatusText == "Mac · Reconnecting"
        )
        #expect(
            NotificationFeedRowModel(item: item(connectionStatus: .unavailable))
                .presentation.computerStatusText == "Mac · Unavailable"
        )
    }

    @Test func accessibilityDetailsCarryReadStateWorkspacePreviewAndComputer() {
        let unread = NotificationFeedRowModel(item: item(
            isRead: false,
            body: "Choose a builder to continue.",
            connectionStatus: .unavailable
        ))

        #expect(unread.presentation.accessibilityDetails == [
            "Unread",
            "Workspace: Workspace",
            "Choose a builder to continue.",
            "Computer: Mac · Unavailable",
        ])

        let read = NotificationFeedRowModel(item: item(isRead: true))
        #expect(read.presentation.accessibilityDetails.first == "Read")
    }

    @Test func equalityComparesTheItemAlone() {
        let first = NotificationFeedRowModel(item: item())
        let second = NotificationFeedRowModel(item: item())

        // Same item produced by two separate rebuilds must compare equal so
        // republished sections do not re-render unchanged rows.
        #expect(first == second)
        #expect(first != NotificationFeedRowModel(item: item(isRead: true)))
    }

    private func item(
        isRead: Bool = false,
        title: String = "Title",
        subtitle: String? = nil,
        body: String = "Body",
        workspaceTitle: String = "Workspace",
        macDisplayName: String = "Mac",
        connectionStatus: MobileMacConnectionStatus = .connected
    ) -> MobileNotificationFeedItem {
        MobileNotificationFeedItem(
            macDeviceID: "mac-a",
            notificationID: "notification",
            macDisplayName: macDisplayName,
            remoteWorkspaceID: "workspace",
            remoteSurfaceID: "surface",
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: Date(timeIntervalSince1970: 1_784_000_000),
            isRead: isRead,
            workspaceTitle: workspaceTitle,
            surfaceTitle: "Terminal",
            connectionStatus: connectionStatus
        )
    }
}
