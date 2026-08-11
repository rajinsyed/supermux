import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
// SUPERMUX:begin notification-feed-project-row
import SupermuxMobileCore
// SUPERMUX:end notification-feed-project-row

/// A compact, immutable projection of the facts a user scans before opening,
/// plus the row's precomputed accessibility details. Built once per item on the
/// projection's background rebuild so row bodies do no string work during
/// scroll.
struct NotificationFeedRowPresentation: Equatable, Sendable {
    // SUPERMUX:begin notification-feed-project-row
    /// The owning project, or `nil`. Carried through to the row so it can draw
    /// the avatar; derived here (not in `body`) like every other row value.
    let project: SupermuxNotificationProject?
    /// The row's primary line.
    ///
    /// The workspace name when known, otherwise the notification's own title —
    /// decided by ``SupermuxNotificationRowPresentation`` so the phone and both
    /// Mac surfaces answer "where do I go" identically. Before this the phone
    /// showed the title, which meant every row in a busy feed read "Claude
    /// Code" while the Mac showed the workspace.
    let headline: String
    /// The secondary line: the project, then the notification's own title when
    /// the headline did not already say it. `nil` when everything would restate
    /// something already on screen.
    let provenance: String?
    // SUPERMUX:end notification-feed-project-row
    let workspaceName: String
    let contentPreview: String?
    let computerName: String
    let connectionStatus: MobileMacConnectionStatus
    /// The spoken details (read state, workspace, preview, computer) minus the
    /// relative time, which the row formats at render so VoiceOver never reads
    /// a timestamp frozen at whatever moment this model was built.
    let accessibilityDetails: [String]

    init(item: MobileNotificationFeedItem) {
        let normalizedTitle = notificationFeedRowNormalized(item.title) ?? item.title
        let normalizedWorkspace = notificationFeedRowNormalized(item.workspaceTitle) ?? L10n.string(
            "mobile.notificationFeed.row.unknownWorkspace",
            defaultValue: "Unknown workspace"
        )
        let normalizedComputer = notificationFeedRowNormalized(item.macDisplayName) ?? item.macDeviceID
        // SUPERMUX:begin notification-feed-project-row
        project = item.project
        let normalizedProject = notificationFeedRowNormalized(item.project?.name)

        // Headline and provenance come from the shared decider rather than being
        // composed here: this is the exact logic the two Mac surfaces run, and
        // the whole reason it is shared is that three hand-rolled copies is how
        // they drifted apart in the first place.
        //
        // The unknown-workspace fallback is deliberately NOT passed as the tab
        // name — "Unknown workspace" is a UI placeholder, not a workspace, and
        // feeding it in would make it the headline and push the real title into
        // the smaller provenance line.
        let knownWorkspace = notificationFeedRowNormalized(item.workspaceTitle)
        headline = SupermuxNotificationRowPresentation.headline(
            title: normalizedTitle,
            tabName: knownWorkspace
        )
        provenance = SupermuxNotificationRowPresentation.provenance(
            projectName: normalizedProject,
            title: normalizedTitle,
            headline: headline
        )
        // SUPERMUX:end notification-feed-project-row

        workspaceName = normalizedWorkspace
        computerName = normalizedComputer
        connectionStatus = item.connectionStatus

        // SUPERMUX:begin notification-feed-project-row
        // Everything already rendered above the preview, so a body that merely
        // repeats one of those lines is not a useful preview. Also from the
        // shared decider, so the Mac and the phone agree on when a body is
        // worth showing and when the subtitle takes over.
        let contentPreview = SupermuxNotificationRowPresentation.preview(
            body: item.body,
            subtitle: item.subtitle,
            redundant: [headline, provenance, normalizedProject, normalizedComputer]
        )
        // SUPERMUX:end notification-feed-project-row
        self.contentPreview = contentPreview

        accessibilityDetails = notificationFeedRowAccessibilityDetails(
            item: item,
            projectName: normalizedProject,
            workspaceName: normalizedWorkspace,
            contentPreview: contentPreview,
            computerStatusText: notificationFeedRowApplyingConnectionStatus(
                item.connectionStatus,
                to: normalizedComputer
            )
        )
    }

    var computerStatusText: String {
        notificationFeedRowApplyingConnectionStatus(connectionStatus, to: computerName)
    }
}

private func notificationFeedRowAccessibilityDetails(
    item: MobileNotificationFeedItem,
    // SUPERMUX:begin notification-feed-project-row
    projectName: String?,
    // SUPERMUX:end notification-feed-project-row
    workspaceName: String,
    contentPreview: String?,
    computerStatusText: String
) -> [String] {
    var details = [
        item.isRead
            ? L10n.string("mobile.notificationFeed.read", defaultValue: "Read")
            : L10n.string("mobile.notificationFeed.unread", defaultValue: "Unread"),
    ]
    // SUPERMUX:begin notification-feed-project-row
    // Spoken before the workspace: the project is the coarser, more orienting
    // fact, and the row ignores child accessibility so this is the only place
    // VoiceOver can learn it.
    if let projectName {
        details.append(notificationFeedRowAccessibilityField(
            label: L10n.string("supermux.notificationFeed.row.project", defaultValue: "Project"),
            value: projectName
        ))
    }
    // SUPERMUX:end notification-feed-project-row
    details.append(notificationFeedRowAccessibilityField(
        label: L10n.string("mobile.notificationFeed.row.workspace", defaultValue: "Workspace"),
        value: workspaceName
    ))
    if let contentPreview {
        details.append(contentPreview)
    }
    details.append(notificationFeedRowAccessibilityField(
        label: L10n.string("mobile.notificationFeed.row.computer", defaultValue: "Computer"),
        value: computerStatusText
    ))
    return details
}

// Localized interpolation, not `String(format:)`: these run per row inside
// the detached whole-window rebuild, and C-varargs formatting is banned in
// concurrent hot paths (the PR 5347 regression class). The catalog values
// keep their positional placeholders; interpolation arguments bind to them
// in order.
private func notificationFeedRowAccessibilityField(label: String, value: String) -> String {
    L10n.string(
        "mobile.notificationFeed.row.fieldFormat",
        defaultValue: "\(label): \(value)"
    )
}

private func notificationFeedRowApplyingConnectionStatus(
    _ connectionStatus: MobileMacConnectionStatus,
    to value: String
) -> String {
    switch connectionStatus {
    case .connected:
        return value
    case .reconnecting:
        return L10n.string(
            "mobile.notificationFeed.macReconnectingFormat",
            defaultValue: "\(value) · Reconnecting"
        )
    case .unavailable:
        return L10n.string(
            "mobile.notificationFeed.macUnavailableFormat",
            defaultValue: "\(value) · Unavailable"
        )
    }
}

private func notificationFeedRowNormalized(_ value: String?) -> String? {
    // SUPERMUX:begin notification-feed-project-row
    // Delegates to the shared normalizer so "blank" means the same thing on
    // every surface — the row's de-duplication is only correct if both sides
    // of a comparison were trimmed by the same rule.
    SupermuxNotificationProvenance.normalized(value)
    // SUPERMUX:end notification-feed-project-row
}
