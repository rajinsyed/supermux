import Foundation
import SupermuxKit

/// Merges the fork's additive fields into each `workspace.list` entry the Mac
/// sends to the phone (architecture §6): `supermux_project_id` (which project
/// the workspace nests under), `supermux_activity` (the agent-activity state
/// behind the sidebar indicator), `supermux_branch` (the sidebar row's branch
/// subtitle), and `supermux_pull_request` (the row's PR badge).
///
/// This is a thin app-target adapter: it gathers the live inputs (the
/// workspace's directory, the ONE shared activity resolution from
/// ``SupermuxWorkspaceActivityResolver``, the SAME branch/PR sources the
/// sidebar's nested row snapshot uses — see `SupermuxWorkspaceRow.snapshot`
/// in `SupermuxTabManagerOpener.swift` — and the app-wide
/// projects/association state from ``SupermuxComposition``) and delegates the
/// actual field computation to the package-unit-tested
/// `SupermuxMobileWorkspaceFields` (SupermuxKit `Mobile/`), so the payload
/// logic itself never forks from its tests. Called from the
/// `mobile-supermux-workspace-fields` fence in
/// `Sources/TerminalController+MobileWorkspaceList.swift`.
@MainActor
enum SupermuxMobileWorkspaceListAugmenter {
    /// Returns `payload` with the workspace's supermux fields merged in.
    /// Workspaces not associated to any project return `payload` unchanged
    /// (no field travels), so upstream-shaped clients see an identical
    /// wire shape for them.
    ///
    /// - Parameters:
    ///   - payload: The upstream-built workspace payload.
    ///   - workspace: The workspace being serialized.
    static func augment(_ payload: [String: Any], workspace: Workspace) -> [String: Any] {
        // Mirror the sidebar row exactly: when the mac row hides its PR badge,
        // the phone must not show one either (same gate as SupermuxAppGlue's
        // pullRequestsEnabled). `pullRequestActivity` is cmux's own resolution
        // — watch-git-status AND show-pull-requests AND the master "Hide all
        // details" switch — and only `.activePolling` means the badge is
        // actually visible (passive states still *accept* agent-pushed PR
        // reports without displaying them).
        let pullRequestPollingEnabled = SidebarWorkspaceDetailDefaults
            .pullRequestActivity(defaults: .standard)
            .performsActivePolling
        let pullRequest = pullRequestPollingEnabled
            ? workspace.sidebarPullRequestsInDisplayOrder().first
                .flatMap(SupermuxPullRequest.init(sidebarState:))
            : nil
        let fields = SupermuxMobileWorkspaceFields.fields(
            workspaceID: workspace.id,
            // The raw directory string, exactly what the sidebar's
            // SupermuxProjectResolutionCache resolves by.
            directory: workspace.currentDirectory,
            activity: SupermuxWorkspaceActivityResolver.activity(for: workspace),
            // The same per-panel branch source the sidebar row's subtitle uses.
            branch: workspace.supermuxSidebarBranch,
            pullRequest: pullRequest,
            projects: SupermuxComposition.projectsModel.projects,
            associations: SupermuxComposition.workspaceAssociations
        )
        guard !fields.isEmpty else { return payload }
        return payload.merging(fields) { _, forkValue in forkValue }
    }
}
