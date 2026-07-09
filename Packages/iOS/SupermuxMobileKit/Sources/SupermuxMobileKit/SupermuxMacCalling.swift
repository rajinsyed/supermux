public import SupermuxMobileCore

/// The typed seam between the phone's supermux stores and the paired Mac's
/// `mobile.supermux.*` RPC surface.
///
/// Stores depend only on this protocol (constructor-injected), so every
/// store is unit-testable against a fake. The production conformance is
/// ``SupermuxMacClient``, a thin adapter over `MobileCoreRPCClient`.
/// Later features extend this protocol with worktrees/changes/run/preset
/// methods as their Mac handlers land.
public protocol SupermuxMacCalling: Sendable {
    /// `mobile.supermux.projects.list`: the registered projects plus the
    /// Mac sidebar section's collapse state.
    func projectsList() async throws -> SupermuxProjectsListResponse

    /// `mobile.supermux.project.icon`: the project's icon as etag'd base64
    /// PNG. Passing the previously returned `etag` lets the Mac answer
    /// `not_modified` without re-sending image bytes.
    ///
    /// - Parameters:
    ///   - projectID: The project's UUID string.
    ///   - etag: The caller's cached etag, if any.
    func projectIcon(projectID: String, etag: String?) async throws -> SupermuxProjectIconResponse

    /// `mobile.supermux.worktrees.list`: one project's worktrees (with
    /// open-workspace state and PR data when available).
    /// - Parameter request: The typed request (owns the exact wire shape).
    func worktreesList(_ request: SupermuxWorktreesListRequest) async throws -> SupermuxWorktreesListResponse

    /// `mobile.supermux.worktree.suggest_branch`: a mac-side branch-name
    /// suggestion (AI when configured, friendly-random otherwise).
    /// - Parameter request: The typed request (owns the exact wire shape).
    func worktreeSuggestBranch(
        _ request: SupermuxWorktreeSuggestBranchRequest
    ) async throws -> SupermuxBranchSuggestionResponse

    /// `mobile.supermux.worktree.create`: creates a worktree and optionally
    /// opens a workspace in it.
    /// - Parameter request: The typed request (owns the exact wire shape).
    func worktreeCreate(_ request: SupermuxWorktreeCreateRequest) async throws -> SupermuxWorktreeCreateResponse

    /// `mobile.supermux.worktree.open`: opens (or focuses) a workspace in an
    /// existing worktree.
    /// - Parameter request: The typed request (owns the exact wire shape).
    func worktreeOpen(_ request: SupermuxWorktreeOpenRequest) async throws -> SupermuxWorktreeOpenResponse

    /// `mobile.supermux.worktree.remove`: removes a worktree. A dirty
    /// worktree without `force` fails with the `dirty_worktree` code.
    /// - Parameter request: The typed request (owns the exact wire shape).
    func worktreeRemove(_ request: SupermuxWorktreeRemoveRequest) async throws -> SupermuxWorktreeRemoveResponse

    /// `mobile.supermux.project.create`: registers a folder as a project
    /// (repo-shipped `config.json` is imported Mac-side).
    /// - Parameter request: The typed request (owns the exact wire shape).
    func projectCreate(_ request: SupermuxProjectCreateRequest) async throws -> SupermuxProjectWriteResponse

    /// `mobile.supermux.project.update`: applies a present-key patch to a
    /// project (arrays replaced whole; explicit `null` clears).
    /// - Parameter request: The typed request (owns the exact wire shape).
    func projectUpdate(_ request: SupermuxProjectUpdateRequest) async throws -> SupermuxProjectWriteResponse

    /// `mobile.supermux.project.delete`: unregisters a project (worktrees and
    /// the repository stay on the Mac's disk).
    /// - Parameter request: The typed request (owns the exact wire shape).
    func projectDelete(_ request: SupermuxProjectDeleteRequest) async throws -> SupermuxProjectDeleteResponse

    /// `mobile.supermux.projects.set_section_collapsed`: persists the sidebar
    /// Projects section's collapse state Mac-side.
    /// - Parameter request: The typed request (owns the exact wire shape).
    func projectsSetSectionCollapsed(
        _ request: SupermuxProjectsSetSectionCollapsedRequest
    ) async throws -> SupermuxSectionCollapsedResponse

    /// `mobile.supermux.preset.create`: appends a launchable terminal preset
    /// (the Mac assigns the identity).
    /// - Parameter request: The typed request (owns the exact wire shape).
    func presetCreate(_ request: SupermuxPresetCreateRequest) async throws -> SupermuxPresetWriteResponse

    /// `mobile.supermux.preset.update`: applies a present-key patch to a
    /// preset.
    /// - Parameter request: The typed request (owns the exact wire shape).
    func presetUpdate(_ request: SupermuxPresetUpdateRequest) async throws -> SupermuxPresetWriteResponse

    /// `mobile.supermux.preset.delete`: removes a preset from the Mac's bar.
    /// - Parameter request: The typed request (owns the exact wire shape).
    func presetDelete(_ request: SupermuxPresetDeleteRequest) async throws -> SupermuxPresetDeleteResponse

    /// Subscribes to `supermux.*` event topics. Events are payload-light
    /// pokes; consumers refetch through the matching request method. The
    /// stream finishes when the underlying connection drops; consumers
    /// resubscribe from their run loops.
    ///
    /// - Parameter topics: The topics to receive.
    /// - Returns: Matching events, in delivery order.
    func events(topics: Set<SupermuxMobileTopic>) async -> AsyncStream<SupermuxMobileEvent>
}
