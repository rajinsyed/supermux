import CMUXMobileCore
import CmuxSidebar
import Foundation
import SupermuxKit

/// Host side of mirror status parity: the additive state-sync v2 fields that
/// let another Mac's mirror row show what this Mac's own sidebar row shows —
/// `supermux_status_entries` (the `cmux set-status` pills), `supermux_progress`
/// (`cmux set-progress`), `supermux_log` (latest `cmux log` line), plus
/// branch/PR for workspaces no project owns (the association-gated augmenter
/// omits them; mirrors of global workspaces still need them).
///
/// Filled from the `supermux-mobile-workspace-fields` fence in
/// `MobileStateSyncHost.workspaceRow`; freshness comes from
/// ``SupermuxMobileSidebarStatusObserver``. Bounded so one busy agent cannot
/// bloat every delta frame.
@MainActor
enum SupermuxMobileWorkspaceStatusFields {
    /// At most this many pills travel per workspace.
    static let maximumStatusEntries = 12
    /// Longest pill value / log message sent, in characters.
    static let maximumTextLength = 240

    /// The row's pills in display order, without the agent lifecycle pills the
    /// activity indicator duplicates (the same dedupe the flat row applies), so
    /// the viewer renders exactly what this Mac shows. Always an array on a
    /// supporting host, so an emptied set clears the viewer's pills.
    static func statusEntries(for workspace: Workspace) -> [WorkspaceSyncRecord.SupermuxStatusEntry] {
        let visible = SupermuxSidebarAgentStatusRows.droppingAgentStatusRows(
            from: workspace.sidebarStatusEntriesInDisplayOrder(),
            duplicatedBy: SupermuxWorkspaceActivityResolver.activityByAgentKey(for: workspace)
        )
        return visible
            .filter { !$0.key.hasPrefix(SupermuxDeviceStatusProjector.remoteStatusKeyPrefix) }
            .prefix(maximumStatusEntries)
            .map { entry in
                WorkspaceSyncRecord.SupermuxStatusEntry(
                    key: entry.key,
                    value: String(entry.value.prefix(maximumTextLength)),
                    icon: entry.icon,
                    color: entry.color,
                    priority: entry.priority == 0 ? nil : entry.priority
                )
            }
    }

    /// The row's progress bar, if any.
    static func progress(for workspace: Workspace) -> WorkspaceSyncRecord.SupermuxProgress? {
        workspace.progress.map { WorkspaceSyncRecord.SupermuxProgress(value: $0.value, label: $0.label) }
    }

    /// The row's latest log line, if any, never a projected remote one.
    static func log(for workspace: Workspace) -> WorkspaceSyncRecord.SupermuxLog? {
        workspace.logEntries.last { $0.source != SupermuxDeviceStatusProjector.remoteLogSource }.map {
            WorkspaceSyncRecord.SupermuxLog(message: String($0.message.prefix(maximumTextLength)), level: $0.level.rawValue)
        }
    }

    /// The branch for a workspace the augmenter left without one (no project).
    static func branch(for workspace: Workspace) -> String? {
        let branch = workspace.supermuxSidebarBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch?.isEmpty == false ? branch : nil
    }

    /// The PR badge for a workspace the augmenter left without one, under the
    /// same "PR badge visible" gate the augmenter uses.
    static func pullRequest(for workspace: Workspace) -> WorkspaceSyncRecord.SupermuxPullRequest? {
        guard SidebarWorkspaceDetailDefaults.pullRequestActivity(defaults: .standard).performsActivePolling,
              let state = workspace.sidebarPullRequestsInDisplayOrder().first else { return nil }
        return WorkspaceSyncRecord.SupermuxPullRequest(
            number: state.number,
            state: state.status.rawValue,
            url: state.url.absoluteString,
            isStale: state.isStale
        )
    }
}
