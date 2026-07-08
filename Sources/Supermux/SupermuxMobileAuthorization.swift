import CMUXMobileCore
import Foundation
import SupermuxMobileCore

/// Central fail-closed attach-ticket scoping table for every
/// `mobile.supermux.*` RPC method (architecture §4).
///
/// `MobileHostService.ticketAuthorizationError` delegates the whole namespace
/// here through the `mobile-supermux-authz` fence. Scoping rules:
///
/// - `changes.*` and `files.*` are **workspace-scoped-permitted**: a ticket
///   pinned to a workspace passes when the request's `workspace_id` matches
///   the pin (and no `project_id` widens the request to a project root).
/// - Everything else (projects, worktrees, presets, run, actions, icon)
///   requires a **Mac-wide** ticket; scoped tickets are rejected.
/// - Any `mobile.supermux.*` method missing from
///   `SupermuxMobileMethod` fails closed for every ticket.
///
/// Stack same-account auth stays automatic and separate: nothing in this
/// table exempts a method from `MobileHostService.requiresAuthorization`
/// (`mobile.host.status` remains the only exemption there).
enum SupermuxMobileAuthorization {
    /// The scope class a method's ticket check enforces.
    enum Scope: Equatable, Sendable {
        /// Only a Mac-wide (unpinned) ticket may call the method.
        case macWide
        /// A workspace-pinned ticket may call the method for its own
        /// workspace; Mac-wide tickets always pass.
        case workspaceScopedPermitted
    }

    /// The namespace this table owns (`mobile.supermux.`).
    static let namespacePrefix = SupermuxMobileMethod.namespacePrefix

    /// Classifies a known method. Exhaustive over the shared constants on
    /// purpose: adding a method to `SupermuxMobileCore` without classifying it
    /// here is a compile error, not a silent default.
    static func scope(for method: SupermuxMobileMethod) -> Scope {
        switch method {
        case .changesWatch, .changesStatus, .changesDiff, .changesStage,
             .changesUnstage, .changesDiscard, .changesCommit,
             .changesGenerateCommitMessage, .changesPush, .changesPull,
             .changesStash, .changesStashPop, .changesHistory,
             .filesList, .filesCreate, .filesRename, .filesDuplicate,
             .filesTrash:
            return .workspaceScopedPermitted
        case .projectsList, .projectCreate, .projectUpdate, .projectDelete,
             .projectOpen, .projectIcon,
             .worktreesList, .worktreeSuggestBranch, .worktreeCreate,
             .worktreeOpen, .worktreeRemove,
             .runState, .runStart, .runStop,
             .presetCreate, .presetUpdate, .presetDelete, .presetLaunch,
             .actionRun:
            return .macWide
        }
    }

    /// Classifies a wire method string, or `nil` when it is not a known
    /// `mobile.supermux.*` constant (callers must fail closed on `nil`).
    static func scope(forMethod method: String) -> Scope? {
        guard let known = SupermuxMobileMethod(rawValue: method) else { return nil }
        return scope(for: known)
    }

    /// The ticket-scoping error for one request, or `nil` when the ticket may
    /// call the method (architecture §4). Mirrors
    /// `MobileHostService.ticketAuthorizationError` semantics: an empty ticket
    /// `workspaceID` means Mac-wide.
    ///
    /// - Parameters:
    ///   - method: The wire method string (`mobile.supermux.*`).
    ///   - params: The request params.
    ///   - ticket: The presented attach ticket.
    /// - Returns: `nil` to permit, or the scoped-ticket error to reject.
    static func ticketError(
        method: String,
        params: [String: Any],
        ticket: CmxAttachTicket
    ) -> MobileHostRPCError? {
        // Unlisted methods fail closed for EVERY ticket, Mac-wide included.
        guard let scope = scope(forMethod: method) else {
            return scopedTicketError
        }
        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty workspaceID means the ticket is Mac-wide (general pairing).
        guard !ticketWorkspaceID.isEmpty else {
            return nil
        }
        switch scope {
        case .macWide:
            return scopedTicketError
        case .workspaceScopedPermitted:
            // A request that names a project root is Mac-scoped regardless of
            // any workspace parameter riding along.
            if let projectID = trimmedString(params["project_id"]), !projectID.isEmpty {
                return scopedTicketError
            }
            guard let requested = trimmedString(params["workspace_id"]), !requested.isEmpty else {
                return scopedTicketError
            }
            return requested == ticketWorkspaceID ? nil : scopedTicketError
        }
    }

    /// Wire-identical twin of `MobileHostService`'s scoped-ticket rejection.
    static var scopedTicketError: MobileHostRPCError {
        MobileHostRPCError(
            code: "forbidden",
            message: "Attach ticket is not valid for this workspace or terminal."
        )
    }

    /// The trimmed string value of a param, or `nil` for non-strings.
    private static func trimmedString(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
