#if DEBUG
public import CmuxMobileShellModel
import Foundation
import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// One in-memory Mac for the workspace-list layout preview: its identity, an
/// RPC client that answers from canned data, and what it advertises.
public struct SupermuxProjectsPreviewMac: Sendable {
    /// The Mac the session serves.
    public let mac: SupermuxMacInfo
    /// The canned RPC seam.
    public let client: any SupermuxMacCalling
    /// The capability strings the Mac advertises.
    public let hostCapabilities: Set<String>
}

/// DEBUG fixture behind `CMUX_UITEST_WORKSPACE_LIST_PREVIEW_SUPERMUX=1`: three
/// Macs, two of which share the `cmux` repository at different paths, so the
/// phone's merged Projects list can be exercised without pairing anything.
///
/// - MacBook Pro (`preview-macbook-pro`/`nightly`, foreground): `cmux` (origin
///   `git@github.com:acme/cmux.git`) and `docs`; workspaces `feat-x` (pinned,
///   cmux), `cmux-main` (cmux, hosts the run), `docs-notes` (docs) and the
///   loose `scratch`.
/// - Studio (`preview-studio`/`stable`): `cmux` (`https://github.com/acme/cmux`,
///   another path) and `infra`; workspaces `cmux-fix` (cmux), `infra-api`
///   (infra), and the cmux group "Ops" (led by `ops-lead`) holding
///   `infra-ops`, which infra owns.
/// - Mac mini (`preview-mini`): no Supermux capabilities; one loose workspace.
public enum SupermuxProjectsPreviewFixture {
    /// The launch-environment switch.
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_LIST_PREVIEW_SUPERMUX"] == "1"
    }

    static let laptop = SupermuxMacInfo(
        macDeviceID: "preview-macbook-pro",
        instanceTag: "nightly",
        displayName: "MacBook Pro",
        colorIndex: 0,
        isForeground: true
    )
    static let studio = SupermuxMacInfo(
        macDeviceID: "preview-studio",
        instanceTag: "stable",
        displayName: "Studio Display Bench With A Very Long Name",
        colorIndex: 1
    )
    static let mini = SupermuxMacInfo(
        macDeviceID: "preview-mini",
        instanceTag: nil,
        displayName: "Mac mini",
        colorIndex: 2
    )

    private static let supermuxCapabilities: Set<String> = [
        SupermuxMobileCapability.projectsV1.rawValue,
        SupermuxMobileCapability.worktreesV1.rawValue,
        SupermuxMobileCapability.runV1.rawValue,
    ]

    /// The three in-memory Macs, foreground first.
    public static var macs: [SupermuxProjectsPreviewMac] {
        [
            SupermuxProjectsPreviewMac(
                mac: laptop,
                client: SupermuxPreviewMacClient(
                    projects: [
                        SupermuxProjectDTO(
                            id: "proj-a-cmux",
                            name: "cmux",
                            rootPath: "/Users/me/src/cmux",
                            colorHex: "#3B82F6",
                            runCommands: ["bun dev"],
                            gitRemoteURL: "git@github.com:acme/cmux.git"
                        ),
                        SupermuxProjectDTO(id: "proj-a-docs", name: "docs", rootPath: "/Users/me/src/docs"),
                    ],
                    worktrees: [
                        "proj-a-cmux": [
                            SupermuxWorktreeDTO(path: "/Users/me/src/cmux-worktrees/login", branch: "feature/login"),
                        ],
                    ],
                    runs: [
                        SupermuxRunStateDTO(projectId: "proj-a-cmux", isRunning: true, command: "bun dev", workspaceId: "ws-cmux-main"),
                    ]
                ),
                hostCapabilities: supermuxCapabilities
            ),
            SupermuxProjectsPreviewMac(
                mac: studio,
                client: SupermuxPreviewMacClient(
                    projects: [
                        SupermuxProjectDTO(
                            id: "proj-b-cmux",
                            name: "cmux",
                            rootPath: "/Volumes/work/cmux",
                            colorHex: "#3B82F6",
                            gitRemoteURL: "https://github.com/acme/cmux"
                        ),
                        SupermuxProjectDTO(id: "proj-b-infra", name: "infra", rootPath: "/Volumes/work/infra"),
                    ],
                    worktrees: [
                        "proj-b-cmux": [
                            SupermuxWorktreeDTO(path: "/Volumes/work/cmux-worktrees/race", branch: "fix/race"),
                        ],
                    ],
                    runs: []
                ),
                hostCapabilities: supermuxCapabilities
            ),
            SupermuxProjectsPreviewMac(
                mac: mini,
                client: SupermuxPreviewMacClient(projects: [], worktrees: [:], runs: []),
                hostCapabilities: []
            ),
        ]
    }

    /// The cmux group on the Studio that holds an infra-owned workspace.
    public static let opsGroupID = MobileWorkspaceGroupPreview.ID(rawValue: "group-studio-ops")

    /// The fixture's workspace rows, in the shell's merged order.
    public static var workspaces: [MobileWorkspacePreview] {
        let now = Date()
        func row(
            _ id: String,
            _ name: String,
            on mac: SupermuxMacInfo,
            project: String? = nil,
            group: MobileWorkspaceGroupPreview.ID? = nil,
            pinned: Bool = false,
            minutesAgo: Double
        ) -> MobileWorkspacePreview {
            var workspace = MobileWorkspacePreview(
                id: .init(rawValue: id),
                macDeviceID: mac.macDeviceID,
                macDisplayName: mac.displayName,
                windowID: "preview-window",
                name: name,
                isPinned: pinned,
                groupID: group,
                previewText: "Agent idle",
                previewAt: now.addingTimeInterval(-minutesAgo * 60),
                lastActivityAt: now.addingTimeInterval(-minutesAgo * 60),
                terminals: [MobileTerminalPreview(id: .init(rawValue: "terminal-\(id)"), name: "Agent")]
            )
            workspace.macInstanceTag = mac.instanceTag
            workspace.machineColorIndex = mac.colorIndex
            workspace.supermuxProjectID = project
            workspace.actionCapabilities.supportsMoveActions = true
            workspace.actionCapabilities.supportsWorkspaceActions = true
            workspace.actionCapabilities.supportsWorkspaceMetadata = true
            workspace.actionCapabilities.supportsReadStateActions = true
            workspace.actionCapabilities.supportsCloseActions = true
            workspace.actionCapabilities.supportsGroupActions = true
            return workspace
        }
        var featX = row("ws-feat-x", "feat-x", on: laptop, project: "proj-a-cmux", pinned: true, minutesAgo: 3)
        featX.supermuxPullRequestNumber = 123
        featX.supermuxPullRequestState = "open"
        return [
            row("ws-cmux-main", "cmux-main", on: laptop, project: "proj-a-cmux", minutesAgo: 1),
            featX,
            row("ws-docs-notes", "docs-notes", on: laptop, project: "proj-a-docs", minutesAgo: 30),
            row("ws-scratch", "scratch", on: laptop, minutesAgo: 8),
            row("ws-cmux-fix", "cmux-fix", on: studio, project: "proj-b-cmux", minutesAgo: 5),
            row("ws-infra-api", "infra-api", on: studio, project: "proj-b-infra", minutesAgo: 12),
            row("ws-ops-lead", "ops-lead", on: studio, group: opsGroupID, minutesAgo: 15),
            row("ws-infra-ops", "infra-ops", on: studio, project: "proj-b-infra", group: opsGroupID, minutesAgo: 20),
            row("ws-mini-shell", "mini-shell", on: mini, minutesAgo: 40),
        ]
    }

    /// The fixture's cmux groups.
    public static var groups: [MobileWorkspaceGroupPreview] {
        [
            MobileWorkspaceGroupPreview(
                id: opsGroupID,
                macDeviceID: studio.macDeviceID,
                macInstanceTag: studio.instanceTag,
                name: "Ops",
                anchorWorkspaceID: "ws-ops-lead"
            ),
        ]
    }
}

/// A canned, in-memory ``SupermuxMacCalling``: lists, worktrees and run state
/// come from the fixture; every write fails as if the Mac were unreachable.
struct SupermuxPreviewMacClient: SupermuxMacCalling {
    let projects: [SupermuxProjectDTO]
    let worktrees: [String: [SupermuxWorktreeDTO]]
    let runs: [SupermuxRunStateDTO]

    func projectsList() async throws -> SupermuxProjectsListResponse {
        SupermuxProjectsListResponse(projects: projects, sectionCollapsed: false)
    }

    func worktreesList(_ request: SupermuxWorktreesListRequest) async throws -> SupermuxWorktreesListResponse {
        SupermuxWorktreesListResponse(worktrees: worktrees[request.projectID] ?? [])
    }

    func runState(_ request: SupermuxRunStateRequest) async throws -> SupermuxRunStateResponse {
        SupermuxRunStateResponse(runs: runs)
    }

    func projectsSetSectionCollapsed(
        _ request: SupermuxProjectsSetSectionCollapsedRequest
    ) async throws -> SupermuxSectionCollapsedResponse {
        SupermuxSectionCollapsedResponse(sectionCollapsed: request.collapsed)
    }

    /// Stays open until the consumer cancels: the continuation keeps itself
    /// alive through its own termination handler, so the stores never see a
    /// "connection drop" and never resubscribe in a loop.
    func events(topics: Set<SupermuxMobileTopic>) async -> AsyncStream<SupermuxMobileEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: SupermuxMobileEvent.self)
        continuation.onTermination = { _ in _ = continuation }
        return stream
    }

    private func unavailable<T>() throws -> T { throw SupermuxMacUnavailableError() }

    func projectIcon(projectID: String, etag: String?) async throws -> SupermuxProjectIconResponse { try unavailable() }
    func worktreeSuggestBranch(_ request: SupermuxWorktreeSuggestBranchRequest) async throws -> SupermuxBranchSuggestionResponse { try unavailable() }
    func worktreeCreate(_ request: SupermuxWorktreeCreateRequest) async throws -> SupermuxWorktreeCreateResponse { try unavailable() }
    func worktreeOpen(_ request: SupermuxWorktreeOpenRequest) async throws -> SupermuxWorktreeOpenResponse { try unavailable() }
    func worktreeRemove(_ request: SupermuxWorktreeRemoveRequest) async throws -> SupermuxWorktreeRemoveResponse { try unavailable() }
    func agentOptions(_ request: SupermuxAgentOptionsRequest) async throws -> SupermuxAgentLaunchOptionsDTO { try unavailable() }
    func agentStart(_ request: SupermuxAgentStartRequest) async throws -> SupermuxAgentStartResponse { try unavailable() }
    func projectCreate(_ request: SupermuxProjectCreateRequest) async throws -> SupermuxProjectWriteResponse { try unavailable() }
    func projectOpen(_ request: SupermuxProjectOpenRequest) async throws -> SupermuxProjectOpenResponse { try unavailable() }
    func projectUpdate(_ request: SupermuxProjectUpdateRequest) async throws -> SupermuxProjectWriteResponse { try unavailable() }
    func projectDelete(_ request: SupermuxProjectDeleteRequest) async throws -> SupermuxProjectDeleteResponse { try unavailable() }
    func presetCreate(_ request: SupermuxPresetCreateRequest) async throws -> SupermuxPresetWriteResponse { try unavailable() }
    func presetUpdate(_ request: SupermuxPresetUpdateRequest) async throws -> SupermuxPresetWriteResponse { try unavailable() }
    func presetDelete(_ request: SupermuxPresetDeleteRequest) async throws -> SupermuxPresetDeleteResponse { try unavailable() }
    func changesWatch(_ request: SupermuxChangesWatchRequest) async throws -> SupermuxChangesWatchResponse { try unavailable() }
    func changesStatus(_ request: SupermuxChangesStatusRequest) async throws -> SupermuxChangesStatusDTO { try unavailable() }
    func changesDiff(_ request: SupermuxChangesDiffRequest) async throws -> SupermuxDiffDTO { try unavailable() }
    func changesStage(_ request: SupermuxChangesStageRequest) async throws -> SupermuxChangesAckResponse { try unavailable() }
    func changesUnstage(_ request: SupermuxChangesUnstageRequest) async throws -> SupermuxChangesAckResponse { try unavailable() }
    func changesDiscard(_ request: SupermuxChangesDiscardRequest) async throws -> SupermuxChangesAckResponse { try unavailable() }
    func changesCommit(_ request: SupermuxChangesCommitRequest) async throws -> SupermuxChangesCommitResponse { try unavailable() }
    func changesGenerateCommitMessage(
        _ request: SupermuxChangesGenerateCommitMessageRequest
    ) async throws -> SupermuxChangesGeneratedMessageResponse { try unavailable() }
    func changesPush(_ request: SupermuxChangesPushRequest) async throws -> SupermuxChangesSyncResponse { try unavailable() }
    func changesPull(_ request: SupermuxChangesPullRequest) async throws -> SupermuxChangesSyncResponse { try unavailable() }
    func changesStash(_ request: SupermuxChangesStashRequest) async throws -> SupermuxChangesSyncResponse { try unavailable() }
    func changesStashPop(_ request: SupermuxChangesStashPopRequest) async throws -> SupermuxChangesSyncResponse { try unavailable() }
    func changesHistory(_ request: SupermuxChangesHistoryRequest) async throws -> SupermuxChangesHistoryResponse { try unavailable() }
    func runStart(_ request: SupermuxRunStartRequest) async throws -> SupermuxRunWriteResponse { try unavailable() }
    func runStop(_ request: SupermuxRunStopRequest) async throws -> SupermuxRunWriteResponse { try unavailable() }
    func presetLaunch(_ request: SupermuxPresetLaunchRequest) async throws -> SupermuxPresetLaunchResponse { try unavailable() }
    func actionRun(_ request: SupermuxActionRunRequest) async throws -> SupermuxActionRunResponse { try unavailable() }
    func filesList(_ request: SupermuxFilesListRequest) async throws -> SupermuxFilesListResponse { try unavailable() }
    func filesCreate(_ request: SupermuxFilesCreateRequest) async throws -> SupermuxFilesMutationResponse { try unavailable() }
    func filesRename(_ request: SupermuxFilesRenameRequest) async throws -> SupermuxFilesMutationResponse { try unavailable() }
    func filesDuplicate(_ request: SupermuxFilesDuplicateRequest) async throws -> SupermuxFilesMutationResponse { try unavailable() }
    func filesTrash(_ request: SupermuxFilesTrashRequest) async throws -> SupermuxFilesMutationResponse { try unavailable() }
    func usageState(_ request: SupermuxUsageStateRequest) async throws -> SupermuxUsageStateDTO { try unavailable() }
}

private struct SupermuxProjectsPreviewMacsKey: EnvironmentKey {
    static let defaultValue: [SupermuxProjectsPreviewMac] = []
}

extension EnvironmentValues {
    /// In-memory Macs the Projects section driver runs instead of the shell's
    /// seams (layout preview only). Empty in every real launch.
    var supermuxProjectsPreviewMacs: [SupermuxProjectsPreviewMac] {
        get { self[SupermuxProjectsPreviewMacsKey.self] }
        set { self[SupermuxProjectsPreviewMacsKey.self] = newValue }
    }
}

extension View {
    /// Runs the Projects section on the fixture's in-memory Macs when
    /// `CMUX_UITEST_WORKSPACE_LIST_PREVIEW_SUPERMUX=1`; inert otherwise.
    public func supermuxProjectsPreviewFixture() -> some View {
        environment(\.supermuxProjectsPreviewMacs, SupermuxProjectsPreviewFixture.isEnabled ? SupermuxProjectsPreviewFixture.macs : [])
    }
}
#endif

#if DEBUG
extension SupermuxProjectsSectionModel {
    /// Runs every fixture Mac's session concurrently until cancelled — the
    /// layout preview's twin of ``runSessions(_:)``.
    func runPreviewSessions(_ previews: [SupermuxProjectsPreviewMac]) async {
        let runs = previews.map { preview in
            Task { [weak self] in
                await self?.runSession(
                    mac: preview.mac,
                    client: preview.client,
                    hostCapabilities: preview.hostCapabilities,
                    connectionID: SupermuxProjectsConnectionKey(previewPairingID: preview.mac.pairingID)
                )
            }
        }
        await withTaskCancellationHandler {
            for run in runs {
                await run.value
            }
        } onCancel: {
            for run in runs {
                run.cancel()
            }
        }
    }
}
#endif
