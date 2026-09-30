import Foundation
import SupermuxMobileCore
import SupermuxMobileKit

/// Everything a pushed project detail screen acts through, bound to the
/// project's OWN Mac: its worktrees, Claude, run, preset and editor calls go
/// to that Mac's client — never simply the foreground Mac — and a workspace
/// it opens is resolved against that Mac's rows. Closure ids are the Mac's
/// plain project ids (``SupermuxProjectRowSnapshot/projectID``).
struct SupermuxProjectDetailContext {
    let row: SupermuxProjectRowSnapshot
    let iconPNGData: @Sendable (_ projectID: String) async -> Data?
    /// Opens a nested workspace by its shell ROW id.
    let selectWorkspace: @MainActor (_ workspaceID: String) -> Void
    /// Opens a workspace by the Mac-local id this project's Mac answered with.
    let openMacWorkspace: @MainActor (_ remoteWorkspaceID: String) -> Void
    let makeWorktreesStore: @MainActor (_ projectID: String) -> SupermuxMobileWorktreesStore?
    let makeAgentLaunchStore: @MainActor (_ projectID: String) -> SupermuxMobileAgentLaunchStore?
    let editing: SupermuxProjectEditingActions
    let runActions: SupermuxProjectRunActions?
    let presets: [SupermuxTerminalPresetDTO]
    let showsPresets: Bool
    let showsActions: Bool
    /// Moves whenever this Mac's connection is replaced or ends.
    let sessionEpoch: Int
    /// The Macs the New Worktree sheet can create on (own Mac first).
    let newWorktreeOptions: [SupermuxNewWorktreeMacOption]
    /// Retargets the New Worktree sheet to another Mac's copy.
    let prepareNewWorktreeTarget: @MainActor (SupermuxNewWorktreeMacOption) async throws -> SupermuxNewWorktreeTarget
}

extension SupermuxProjectsSectionModel {
    /// The routed detail project's context, or `nil` while none is routed.
    var detailContext: SupermuxProjectDetailContext? {
        guard let row = detailRow else { return nil }
        let session = sessions[row.pairingID]
        let group = snapshot.group(forRowID: row.id)
        let mac = session?.mac
        return SupermuxProjectDetailContext(
            row: row,
            iconPNGData: actions.iconPNGData,
            selectWorkspace: { [weak self] workspaceID in
                self?.navigateToWorkspace(workspaceID)
            },
            openMacWorkspace: { [weak self] remoteWorkspaceID in
                self?.navigateToMacWorkspace(remoteWorkspaceID, on: mac)
            },
            makeWorktreesStore: { [weak session] projectID in
                session?.makeWorktreesStore(forProjectID: projectID)
            },
            makeAgentLaunchStore: { [weak session] projectID in
                session?.makeAgentLaunchStore(forProjectID: projectID)
            },
            editing: session?.editingActions ?? Self.unavailableEditingActions,
            runActions: session?.runActions,
            presets: group?.presets ?? [],
            showsPresets: group?.showsPresets ?? false,
            showsActions: group?.showsActions ?? false,
            sessionEpoch: session?.epoch ?? counter.value,
            newWorktreeOptions: newWorktreeOptions(forProjectID: row.id),
            prepareNewWorktreeTarget: { [weak self] option in
                guard let self else { throw SupermuxMacUnavailableError() }
                return try await self.prepareNewWorktreeTarget(option)
            }
        )
    }
}
