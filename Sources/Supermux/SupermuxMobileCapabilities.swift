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
        served + (servesPortForward ? [SupermuxMobileCapability.portForwardV1.rawValue] : [])
            + (servesTerminalStream ? [SupermuxMobileCapability.terminalStreamV1.rawValue] : [])
    }

    /// terminal.watch is served and mobile.terminal.replay resumes from a byte
    /// position: another Mac's device mirror streams a terminal losslessly
    /// instead of re-anchoring on full replays. A DEBUG E2E can withhold it to
    /// play an older host.
    nonisolated private static var servesTerminalStream: Bool {
        #if DEBUG
        if SupermuxTerminalStreamDebug.pretendsOldHost { return false }
        #endif
        return true
    }

    /// Port forwarding (another Mac's `tcp_connect` lanes, `ports.list`,
    /// `supermux.ports.updated`) is served unless an administrator disabled
    /// the embedded browser, which also closes the tunnel host
    /// (`MobileHostBrowserTunnel.isAvailable`), as upstream withholds
    /// `browser.tunnel.v1`.
    nonisolated private static var servesPortForward: Bool {
        #if DEBUG
        if SupermuxDeviceTunnelSocketCommands.pretendsOldHost { return false }
        #endif
        return MobileHostBrowserTunnel.isAvailable
    }

    /// The capabilities served unconditionally.
    nonisolated private static var served: [String] {
        [
            SupermuxMobileCapability.projectsV1.rawValue,
            // Workspace-list payloads carry the additive supermux_activity
            // field (and the activity observer re-emits workspace.updated on
            // agent lifecycle changes).
            SupermuxMobileCapability.activityV1.rawValue,
            // worktrees.list / worktree.suggest_branch / worktree.create /
            // worktree.open / worktree.remove (and project.open) are served.
            SupermuxMobileCapability.worktreesV1.rawValue,
            // The full preset namespace is served: preset.create /
            // preset.update / preset.delete / preset.launch.
            SupermuxMobileCapability.presetsV1.rawValue,
            // The full changes.* namespace is served: watch / status / diff /
            // stage / unstage / discard plus commit /
            // generate_commit_message / push / pull / stash / stash_pop /
            // history.
            SupermuxMobileCapability.changesV1.rawValue,
            // run.state / run.start / run.stop are served (and the run
            // observer emits supermux.run.updated on transitions).
            SupermuxMobileCapability.runV1.rawValue,
            // action.run is served.
            SupermuxMobileCapability.actionsV1.rawValue,
            // The full files namespace is served: files.list / files.create /
            // files.rename / files.duplicate / files.trash (root-confined,
            // trash-only deletion).
            SupermuxMobileCapability.filesV1.rawValue,
            // v1 preserves compatibility with phones that know only terminal
            // focus; v2 adds browser, Simulator, and every other panel kind via
            // the same shared focus path as the Mac UI and control socket.
            SupermuxMobileCapability.selectionSyncV1.rawValue,
            SupermuxMobileCapability.selectionSyncV2.rawValue,
            // Generic workspace-panel close and native Simulator creation are
            // served. The latter still checks the upstream Simulator feature
            // flag and capability at request/UI time.
            SupermuxMobileCapability.panesV1.rawValue,
            // The fixed-identity Supermux phone can register its sandbox APNs
            // token for direct, personal-team delivery from this Mac.
            SupermuxMobileCapability.phonePushV1.rawValue,
            // usage.state is served: the read-only Claude Code + Codex
            // rate-limit mirror of the sidebar's usage tracker.
            SupermuxMobileCapability.usageV1.rawValue,
            // agent.options / agent.start are served: prompt-first worktree
            // creation that opens a workspace already running Claude.
            SupermuxMobileCapability.agentLaunchV1.rawValue,
            // phone_push.status / phone_push.share are served: another of the
            // user's Macs can fill this Mac's missing direct-APNs credentials
            // and phone registrations over the device link.
            SupermuxMobileCapability.phonePushShareV1.rawValue,
            // project.probe / project.clone are served: other Macs register
            // their copy of a repo here (project sync) and "Set Up on <Mac>…".
            SupermuxMobileCapability.projectSetupV1.rawValue,
            // mobile.terminal.input takes `supermux_input`: another Mac's
            // device mirror sends its keys as key events and its other input
            // as exact bytes, so typing there behaves as typing here.
            SupermuxMobileCapability.terminalInputV1.rawValue,
            // device.workspace.terminal.create takes `after_surface_id`: another
            // Mac's "New Terminal to the Right" lands right of its tab here too.
            SupermuxMobileCapability.terminalPlacementV1.rawValue,
            // files.list {show_hidden} / files.read / files.search /
            // files.git_status / files.watch are served: another Mac's Files
            // panel browses a workspace's folder here, read-only and
            // root-confined, and refreshes when the folder's entries change.
            SupermuxMobileCapability.filesReadV1.rawValue,
            // simulator.control is served and simulator.create takes `udid`:
            // another Mac's device mirror shows this Mac's simulators (the
            // video itself is upstream's simulator.stream.v2 lane).
            SupermuxMobileCapability.remoteSimulatorV1.rawValue,
            // mobile.terminal.size_policy.set takes `supermux_preference`: a
            // size mode picked on another Mac's mirror becomes this Mac's
            // setting for all its terminals.
            SupermuxMobileCapability.terminalSizingPreferenceV1.rawValue,
        ]
    }
}
