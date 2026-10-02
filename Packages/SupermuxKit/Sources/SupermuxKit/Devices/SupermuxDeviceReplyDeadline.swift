public import Foundation
internal import SupermuxMobileCore

/// How long a Mac waits for another Mac's reply to one call over the device
/// link: the one audited per-method table. `SupermuxDevices.request` applies
/// it to every call that does not name its own deadline, so no caller can
/// forget a long one.
///
/// A missed deadline fails the call: the caller sees `timed_out` while the
/// work may still be running on the owning Mac. (Before #723 the device link
/// also took it as a dead transport and reconnected, dropping every mirror of
/// that Mac; now it reconnects only when that Mac stops answering.) So each
/// method's deadline must outlast everything the owning Mac may legitimately
/// do for it. The host bounds each step itself (30 s per local git command,
/// 30 s for a background `git fetch`, 120 s for push and pull, 30 s for an AI
/// request, 600 s for a worktree checkout, 900 s for a clone, 30 s for a
/// `files.*` call and 300 s for a file duplicate or trash), and the
/// deadlines below are derived from those bounds. `nil` keeps the link's own
/// 20 s default, which suits calls the host answers from memory or within a
/// few seconds of its own bounds (`projects.list`, `run.state`,
/// `project.icon`, the `preset.*` calls and every call that names a project
/// wait at most 2 s for the projects' first load).
///
/// ```swift
/// devices.request(.changesHistory, params: params, on: machine)   // gets `network`
/// ```
public enum SupermuxDeviceReplyDeadline {
    /// The host's bound on one local git command.
    private static let git = SupermuxGitChangesService.gitTimeout

    /// A few local git commands, an AI request, or a Claude catalog probe.
    public static let localWork: Duration = seconds(4 * git)
    /// A host `git fetch`, push or pull, plus the git reads around it.
    public static let network: Duration = seconds(SupermuxGitChangesService.networkTimeout + 2 * git)
    /// Creating or removing a worktree: its teardown script, the
    /// `git worktree add/remove` checkout, and the git commands around them.
    public static let checkout: Duration = seconds(
        SupermuxGitWorktreeService.checkoutTimeout + SupermuxGitWorktreeService.teardownTimeout + 3 * git
    )
    /// `git clone`, then registering the project.
    public static let clone: Duration = seconds(SupermuxProjectSetupService.cloneTimeout + 4 * git)
    /// A `files.duplicate` or `files.trash`: the host's bound on copying or
    /// moving a whole tree.
    public static let fileCopy: Duration = seconds(SupermuxMobileFileBrowser.copyTimeout + git)

    /// The reply deadline for a wire method, or `nil` for the link default
    /// (every method that is not a `mobile.supermux.*` call).
    /// - Parameter wireMethod: The JSON-RPC method, e.g. `mobile.supermux.changes.history`.
    public static func forMethod(_ wireMethod: String) -> Duration? {
        SupermuxMobileMethod(rawValue: wireMethod).flatMap(forMethod)
    }

    /// Exhaustive on purpose: a new method must be classified here.
    static func forMethod(_ method: SupermuxMobileMethod) -> Duration? {
        switch method {
        case .changesHistory, .changesPush, .changesPull:
            return network
        case .changesStatus, .changesDiff, .changesStage, .changesUnstage, .changesDiscard,
             .changesCommit, .changesGenerateCommitMessage, .changesStash, .changesStashPop,
             .worktreesList, .worktreeSuggestBranch, .agentOptions, .projectCreate, .projectProbe,
             .filesList, .filesRead, .filesCreate, .filesRename, .filesSearch, .filesGitStatus:
            // The host answers each of these files.* calls within
            // SupermuxMobileFileBrowser.operationTimeout (gitStatusTimeout
            // for git_status), timed out or not.
            return localWork
        case .filesDuplicate, .filesTrash:
            return fileCopy
        case .worktreeCreate, .worktreeRemove, .agentStart:
            return checkout
        case .projectClone:
            return clone
        case .projectsList, .projectUpdate, .projectDelete, .projectOpen, .projectIcon,
             .projectsSetSectionCollapsed, .worktreeOpen, .changesWatch, .filesWatch, .runState, .runStart, .runStop,
             .presetCreate, .presetUpdate, .presetDelete, .presetLaunch, .actionRun,
             .workspaceSelect, .terminalSelect, .panelSelect, .paneClose, .simulatorCreate, .simulatorControl,
             .usageState, .phonePushRegister, .phonePushStatus, .phonePushShare, .portsList:
            return nil
        }
    }

    private static func seconds(_ value: TimeInterval) -> Duration {
        .seconds(Int(value.rounded(.up)))
    }
}
