import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation
// SUPERMUX:begin notification-feed-project-row
import SupermuxMobileCore
// SUPERMUX:end notification-feed-project-row

/// A compact, immutable projection of the four facts a user scans before
/// opening, plus the row's precomputed accessibility details. Built once per
/// item on the projection's background rebuild so row bodies do no string
/// work during scroll.
struct NotificationFeedRowPresentation: Equatable, Sendable {
    // SUPERMUX:begin notification-feed-project-row
    /// The owning project, or `nil`. Carried through to the row so it can draw
    /// the avatar; derived here (not in `body`) like every other row value.
    let project: SupermuxNotificationProject?
    /// The project's display name once normalized, or `nil` when it is blank
    /// or merely restates the workspace name — a workspace named after its repo
    /// is the common case, and "supermux · supermux" is noise.
    let projectName: String?
    // SUPERMUX:end notification-feed-project-row
    let workspaceName: String
    let workspaceMatchesTitle: Bool
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
        projectName = normalizedProject.flatMap { name in
            notificationFeedRowMatches(name, normalizedWorkspace) ? nil : name
        }
        // SUPERMUX:end notification-feed-project-row

        workspaceName = normalizedWorkspace
        workspaceMatchesTitle = notificationFeedRowMatches(normalizedWorkspace, normalizedTitle)
        computerName = normalizedComputer
        connectionStatus = item.connectionStatus

        // SUPERMUX:begin notification-feed-project-row
        // The project name now renders on its own line, so a body that merely
        // repeats it is not a useful preview.
        let redundantContent = [normalizedTitle, normalizedWorkspace, normalizedComputer]
            + [normalizedProject].compactMap { $0 }
        // SUPERMUX:end notification-feed-project-row
        let contentPreview: String?
        if let body = notificationFeedRowNormalized(item.body),
           !notificationFeedRowMatchesAny(body, redundantContent) {
            contentPreview = body
        } else if let subtitle = notificationFeedRowNormalized(item.subtitle),
                  !notificationFeedRowMatchesAny(subtitle, redundantContent) {
            // The desktop feed treats title + body as the primary content. The
            // optional subtitle becomes useful only when the body adds nothing.
            contentPreview = subtitle
        } else {
            contentPreview = nil
        }
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
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else { return nil }
    return value
}

private func notificationFeedRowMatchesAny(_ candidate: String, _ values: [String]) -> Bool {
    values.contains { notificationFeedRowMatches(candidate, $0) }
}

private func notificationFeedRowMatches(_ lhs: String, _ rhs: String) -> Bool {
    notificationFeedRowCanonical(lhs) == notificationFeedRowCanonical(rhs)
}

private func notificationFeedRowCanonical(_ value: String) -> String {
    value
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}
