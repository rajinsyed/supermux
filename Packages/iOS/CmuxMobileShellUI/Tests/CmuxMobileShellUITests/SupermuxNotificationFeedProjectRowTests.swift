import CmuxMobileShellModel
import Foundation
import SupermuxMobileCore
import Testing
@testable import CmuxMobileShellUI

/// Behavior coverage for the project identity the iOS feed row renders.
///
/// These rules must hold in `NotificationFeedRowPresentation.init` specifically
/// — it runs on the projection's background rebuild, and moving any of this
/// derivation into a row body is the documented scroll regression the whole
/// presentation type exists to prevent.
@Suite struct SupermuxNotificationFeedProjectRowTests {

    @Test func projectTravelsToThePresentation() {
        let model = NotificationFeedRowModel(item: item(
            project: SupermuxNotificationProject(
                id: "project-1", name: "supermux", colorHex: "#3b82f6"
            )
        ))
        #expect(model.presentation.project?.id == "project-1")
        #expect(model.presentation.projectName == "supermux")
    }

    @Test func projectlessNotificationRendersUpstreamShape() {
        // A fork phone paired with an upstream cmux Mac, or a workspace in no
        // project: nothing project-shaped may appear.
        let model = NotificationFeedRowModel(item: item(project: nil))
        #expect(model.presentation.project == nil)
        #expect(model.presentation.projectName == nil)
    }

    @Test func projectNameIsDroppedWhenItRestatesTheWorkspace() {
        // The common case — a workspace named after its repo. Rendering
        // "supermux · supermux" is noise, so the name is suppressed while the
        // project itself stays (the avatar still draws).
        let model = NotificationFeedRowModel(item: item(
            workspaceTitle: "Supermux",
            project: SupermuxNotificationProject(id: "project-1", name: "supermux")
        ))
        #expect(model.presentation.projectName == nil)
        #expect(model.presentation.project != nil)
    }

    @Test func blankProjectNameDoesNotRenderAsAnEmptyLabel() {
        let model = NotificationFeedRowModel(item: item(
            project: SupermuxNotificationProject(id: "project-1", name: "   ")
        ))
        #expect(model.presentation.projectName == nil)
    }

    @Test func bodyRestatingTheProjectIsNotShownAsAPreview() {
        // The project renders on its own line now, so a body repeating it adds
        // nothing and should fall through to the subtitle.
        let model = NotificationFeedRowModel(item: item(
            subtitle: "Tests passed",
            body: "supermux",
            project: SupermuxNotificationProject(id: "project-1", name: "supermux")
        ))
        #expect(model.presentation.contentPreview == "Tests passed")
    }

    @Test func accessibilitySpeaksTheProjectBeforeTheWorkspace() {
        let model = NotificationFeedRowModel(item: item(
            body: "Choose a builder to continue.",
            project: SupermuxNotificationProject(id: "project-1", name: "supermux")
        ))
        #expect(model.presentation.accessibilityDetails == [
            "Unread",
            "Project: supermux",
            "Workspace: Workspace",
            "Choose a builder to continue.",
            "Computer: Mac",
        ])
    }

    @Test func accessibilityOmitsTheProjectFieldWhenThereIsNone() {
        let model = NotificationFeedRowModel(item: item(project: nil))
        #expect(!model.presentation.accessibilityDetails.contains { $0.hasPrefix("Project:") })
    }

    /// Row equality compares the item alone (presentation is a pure
    /// derivation), so a changed project must still re-render the row.
    @Test func changingTheProjectChangesRowEquality() {
        let alpha = NotificationFeedRowModel(item: item(
            project: SupermuxNotificationProject(id: "a", name: "alpha")
        ))
        let beta = NotificationFeedRowModel(item: item(
            project: SupermuxNotificationProject(id: "b", name: "beta")
        ))
        #expect(alpha != beta)
        #expect(alpha == NotificationFeedRowModel(item: item(
            project: SupermuxNotificationProject(id: "a", name: "alpha")
        )))
    }

    /// `updating(...)` re-lists every field; dropping the project there would
    /// blank the avatar the first time a row was marked read.
    @Test func markingReadPreservesTheProject() {
        let original = item(project: SupermuxNotificationProject(id: "a", name: "alpha"))
        let updated = original.updating(isRead: true)
        #expect(updated.project == original.project)
        #expect(updated.isRead)
    }

    private func item(
        isRead: Bool = false,
        title: String = "Title",
        subtitle: String? = nil,
        body: String = "Body",
        workspaceTitle: String = "Workspace",
        macDisplayName: String = "Mac",
        connectionStatus: MobileMacConnectionStatus = .connected,
        project: SupermuxNotificationProject? = nil
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
            connectionStatus: connectionStatus,
            project: project
        )
    }
}
