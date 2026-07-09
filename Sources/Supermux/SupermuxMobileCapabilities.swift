import Foundation
import SupermuxMobileCore

/// The `supermux.*` capabilities this host advertises to mobile clients,
/// appended to `MobileHostService.mobileHostCapabilities` through the
/// `mobile-supermux-capabilities` fence.
///
/// The phone hides every supermux entry point unless the matching capability
/// is advertised, so a fork phone paired with upstream cmux renders exactly
/// today's UI. Entries are added here only once their methods are actually
/// served by `TerminalController.v2MobileSupermuxDispatch`.
enum SupermuxMobileCapabilities {
    /// Capabilities whose backing RPC methods are implemented on this host.
    nonisolated static var advertised: [String] {
        [
            SupermuxMobileCapability.projectsV1.rawValue,
            // Workspace-list payloads carry the additive supermux_activity
            // field (and the activity observer re-emits workspace.updated on
            // agent lifecycle changes).
            SupermuxMobileCapability.activityV1.rawValue,
            // worktrees.list / worktree.suggest_branch / worktree.create /
            // worktree.open / worktree.remove (and project.open) are served.
            SupermuxMobileCapability.worktreesV1.rawValue,
            // preset.create / preset.update / preset.delete are served.
            // preset.launch stays method_not_found until the launch feature
            // ships (m4); the phone must tolerate that error meanwhile.
            SupermuxMobileCapability.presetsV1.rawValue,
            // changes.watch / changes.status / changes.diff / changes.stage /
            // changes.unstage / changes.discard are served — the minimum
            // useful read+mutate surface. changes.commit / push / pull /
            // stash / stash_pop / history / generate_commit_message stay
            // method_not_found until the next changes feature (m3-f2); the
            // phone must tolerate that error meanwhile.
            SupermuxMobileCapability.changesV1.rawValue,
        ]
    }
}
