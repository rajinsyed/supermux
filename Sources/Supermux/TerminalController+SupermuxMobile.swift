import Foundation
import SupermuxMobileCore

/// The `mobile.supermux.*` RPC router: the single dispatch case in
/// `mobileHostHandleRPC` (the `mobile-supermux-dispatch` fence) routes the
/// whole namespace here, mirroring `TerminalController+MobileChat.swift`, so
/// the upstream god-file grows by one fenced case regardless of how many
/// supermux methods exist.
///
/// Ticket scoping for these methods is enforced upstream of dispatch by
/// ``SupermuxMobileAuthorization`` (the `mobile-supermux-authz` fence in
/// `MobileHostService`); handlers here can assume an authorized caller.
extension TerminalController {
    /// Routes one `mobile.supermux.*` method to its handler.
    ///
    /// - Parameters:
    ///   - method: The wire method string.
    ///   - params: The request params.
    /// - Returns: The handler's result, or `method_not_found` for methods this
    ///   host does not serve (yet) — the phone gates each screen on the
    ///   advertised ``SupermuxMobileCapabilities`` instead of probing.
    func v2MobileSupermuxDispatch(method: String, params: [String: Any]) async -> V2CallResult {
        switch SupermuxMobileMethod(rawValue: method) {
        case .projectsList:
            return await v2SupermuxProjectsList(params: params)
        case .projectCreate:
            return await v2SupermuxProjectCreate(params: params)
        case .projectUpdate:
            return await v2SupermuxProjectUpdate(params: params)
        case .projectDelete:
            return await v2SupermuxProjectDelete(params: params)
        case .projectsSetSectionCollapsed:
            return await v2SupermuxProjectsSetSectionCollapsed(params: params)
        case .projectIcon:
            return await v2SupermuxProjectIcon(params: params)
        case .projectOpen:
            return await v2SupermuxProjectOpen(params: params)
        case .presetCreate:
            return await v2SupermuxPresetCreate(params: params)
        case .presetUpdate:
            return await v2SupermuxPresetUpdate(params: params)
        case .presetDelete:
            return await v2SupermuxPresetDelete(params: params)
        case .worktreesList:
            return await v2SupermuxWorktreesList(params: params)
        case .worktreeSuggestBranch:
            return await v2SupermuxWorktreeSuggestBranch(params: params)
        case .worktreeCreate:
            return await v2SupermuxWorktreeCreate(params: params)
        case .worktreeOpen:
            return await v2SupermuxWorktreeOpen(params: params)
        case .worktreeRemove:
            return await v2SupermuxWorktreeRemove(params: params)
        case .changesWatch:
            return await v2SupermuxChangesWatch(params: params)
        case .changesStatus:
            return await v2SupermuxChangesStatus(params: params)
        case .changesDiff:
            return await v2SupermuxChangesDiff(params: params)
        case .changesStage:
            return await v2SupermuxChangesStage(params: params)
        case .changesUnstage:
            return await v2SupermuxChangesUnstage(params: params)
        case .changesDiscard:
            return await v2SupermuxChangesDiscard(params: params)
        case .changesCommit:
            return await v2SupermuxChangesCommit(params: params)
        case .changesGenerateCommitMessage:
            return await v2SupermuxChangesGenerateCommitMessage(params: params)
        case .changesPush:
            return await v2SupermuxChangesPush(params: params)
        case .changesPull:
            return await v2SupermuxChangesPull(params: params)
        case .changesStash:
            return await v2SupermuxChangesStash(params: params)
        case .changesStashPop:
            return await v2SupermuxChangesStashPop(params: params)
        case .changesHistory:
            return await v2SupermuxChangesHistory(params: params)
        default:
            return .err(code: "method_not_found", message: "Unknown mobile method", data: [
                "method": method
            ])
        }
    }
}
