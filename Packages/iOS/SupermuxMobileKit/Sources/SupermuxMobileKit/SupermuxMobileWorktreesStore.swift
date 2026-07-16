public import Foundation
import Observation
public import SupermuxMobileCore

/// Where a worktree-removal flow currently stands. The dirty-worktree branch
/// is the UI-03 contract: a `dirty_worktree` error must park in
/// ``awaitingForceConfirmation(worktreePath:message:)`` — a visible
/// confirm-force state, never a silent failure.
public enum SupermuxWorktreeRemovalState: Equatable, Sendable {
    /// No removal in flight.
    case idle
    /// A remove request is on the wire.
    case removing(worktreePath: String)
    /// The Mac refused with `dirty_worktree`; the user must confirm a forced
    /// retry (or dismiss). ``branch`` captures the worktree's checked-out
    /// branch AT THE TIME of the refusal — the identity a force-confirm
    /// retry is checked against, since ``SupermuxWorktreeDTO`` only
    /// guarantees `path` as a stable identity and a worktree can be removed
    /// and a DIFFERENT one recreated at the same path before the user taps
    /// confirm.
    case awaitingForceConfirmation(worktreePath: String, branch: String?, message: String)
    /// The removal failed terminally; the message is user-facing.
    case failed(worktreePath: String, message: String)
    /// A confirm-force retry no longer matches the worktree at ``worktreePath``
    /// (removed and recreated there since the dialog was raised) — the
    /// force-remove was aborted rather than deleting the wrong worktree; the
    /// UI must re-prompt from a fresh state, not retry silently.
    case confirmationStale(worktreePath: String)
}

/// Main-actor state for one project's worktree list on the phone: the list
/// itself, event-driven refetches, and the create/open/remove actions.
///
/// Depends only on the ``SupermuxMacCalling`` seam and a fixed
/// ``SupermuxMobileCapabilities`` snapshot, both constructor-injected. Every
/// entry point is hidden (and the store inert) unless the host advertises
/// `supermux.worktrees.v1`.
///
/// Lifecycle: the project detail screen runs ``run()`` inside its `.task`
/// modifier, so the live subscription is structured — cancelled automatically
/// when the screen disappears.
@MainActor
@Observable
public final class SupermuxMobileWorktreesStore {
    /// The project's worktrees, in the Mac's order.
    public private(set) var worktrees: [SupermuxWorktreeDTO] = []

    /// Whether at least one fetch has succeeded (drives placeholder vs list).
    public private(set) var hasLoaded = false

    /// Whether the live event stream is currently up.
    public private(set) var isConnected = false

    /// Human-readable description of the most recent fetch failure, for a
    /// non-blocking error surface. Cleared on the next success.
    public private(set) var lastErrorDescription: String?

    /// Where the removal flow currently stands (UI-03 state machine).
    public private(set) var removal: SupermuxWorktreeRemovalState = .idle

    /// The project whose worktrees this store follows (UUID string).
    public let projectID: String

    @ObservationIgnored private let client: any SupermuxMacCalling
    @ObservationIgnored private let capabilities: SupermuxMobileCapabilities
    @ObservationIgnored private let onWorktreesChanged: (@MainActor (_ projectID: String, _ worktrees: [SupermuxWorktreeDTO]) -> Void)?
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Cancellable reconnect-backoff sleep; injectable for deterministic tests.
    @ObservationIgnored private let idleSleep: (Duration) async -> Void

    /// Whether the phone shows worktree UI at all: gated on the host
    /// advertising `supermux.worktrees.v1`.
    public var showsWorktrees: Bool { capabilities.supportsWorktrees }

    /// Creates a worktrees store for one project.
    ///
    /// - Parameters:
    ///   - client: The Mac RPC seam.
    ///   - capabilities: The connected host's capability snapshot.
    ///   - projectID: The project's UUID string.
    ///   - onWorktreesChanged: Called after every successful fetch with the
    ///     fresh worktree list (feeds the project row's count badge and the
    ///     inline nested rows).
    ///   - now: Clock seam for the reconnect-health check.
    ///   - idleSleep: Backoff sleep seam; defaults to `Task.sleep`.
    public init(
        client: any SupermuxMacCalling,
        capabilities: SupermuxMobileCapabilities,
        projectID: String,
        onWorktreesChanged: (@MainActor (_ projectID: String, _ worktrees: [SupermuxWorktreeDTO]) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        idleSleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.capabilities = capabilities
        self.projectID = projectID
        self.onWorktreesChanged = onWorktreesChanged
        self.now = now
        self.idleSleep = idleSleep
    }

    /// Follows the live `supermux.worktrees.updated` stream until cancelled,
    /// refetching inside each subscription so no poke falls into a
    /// fetch/subscribe gap. A no-op without `supermux.worktrees.v1` — against
    /// an upstream Mac the store never issues a request. Mirrors
    /// ``SupermuxMobileProjectsStore/run()``.
    public func run() async {
        guard capabilities.supportsWorktrees else { return }
        var backoff: Duration = .zero
        while !Task.isCancelled {
            // Subscribe FIRST: pokes emitted while the fetch is in flight
            // buffer in the stream and replay after it, instead of dropping.
            let stream = await client.events(topics: [.worktreesUpdated])
            isConnected = true
            let streamStartedAt = now()
            await refetch()
            for await event in stream where event.topic == .worktreesUpdated {
                await refetch()
            }
            isConnected = false
            guard !Task.isCancelled else { return }
            // Liveness, not traffic, is the health signal — an idle stream can
            // legitimately stay silent for hours.
            let streamWasHealthy = now().timeIntervalSince(streamStartedAt) > 5
            if streamWasHealthy {
                backoff = .zero
            } else {
                backoff = min(max(backoff * 2, .milliseconds(500)), .seconds(16))
                await idleSleep(backoff)
            }
        }
    }

    /// `mobile.supermux.worktree.suggest_branch`: asks the Mac to name a
    /// branch (AI when configured mac-side, friendly-random otherwise).
    /// - Parameter workspaceName: The typed workspace name, if any; blank is
    ///   omitted from the wire.
    /// - Returns: The suggestion (`branchName` + `source`).
    public func suggestBranchName(workspaceName: String?) async throws -> SupermuxBranchSuggestionResponse {
        try await client.worktreeSuggestBranch(
            SupermuxWorktreeSuggestBranchRequest(workspaceName: normalized(workspaceName))
        )
    }

    /// `mobile.supermux.worktree.create`: creates a worktree (blank branch →
    /// mac-side naming) and optionally opens a workspace in it. Refreshes the
    /// list on success; errors rethrow for the sheet to display.
    ///
    /// - Parameters:
    ///   - workspaceName: The workspace title, if any; blank is omitted.
    ///   - branchName: The explicit branch name, if any; blank is omitted.
    ///   - open: Whether the Mac opens a workspace in the new worktree.
    /// - Returns: The Mac's result (`worktree` + `workspaceId` when opened).
    public func createWorktree(
        workspaceName: String?,
        branchName: String?,
        open: Bool
    ) async throws -> SupermuxWorktreeCreateResponse {
        let response = try await client.worktreeCreate(SupermuxWorktreeCreateRequest(
            projectID: projectID,
            workspaceName: normalized(workspaceName),
            branchName: normalized(branchName),
            open: open
        ))
        await refetch()
        return response
    }

    /// `mobile.supermux.worktree.open`: opens (or focuses) a workspace in an
    /// existing worktree. Re-opening never re-runs setup (mac-side rule).
    /// - Parameter path: The worktree's absolute path on the Mac.
    /// - Returns: The opened workspace's id, when the Mac reported one.
    public func openWorktree(path: String) async throws -> String? {
        let response = try await client.worktreeOpen(
            SupermuxWorktreeOpenRequest(projectID: projectID, worktreePath: path)
        )
        await refetch()
        return response.workspaceId
    }

    /// `mobile.supermux.worktree.remove`: removes a worktree, driving the
    /// ``removal`` state machine. A `dirty_worktree` refusal on a non-forced
    /// attempt parks in ``SupermuxWorktreeRemovalState/awaitingForceConfirmation(worktreePath:message:)``
    /// so the UI can offer a confirm-force retry; any other error (or a dirty
    /// error on a forced attempt) is terminal ``SupermuxWorktreeRemovalState/failed(worktreePath:message:)``.
    ///
    /// - Parameters:
    ///   - path: The worktree's absolute path on the Mac.
    ///   - force: Whether to remove despite uncommitted changes.
    public func removeWorktree(path: String, force: Bool = false) async {
        if case .removing = removal { return }
        if force, case let .awaitingForceConfirmation(confirmedPath, confirmedBranch, _) = removal,
           confirmedPath == path {
            // A force retry FROM the confirm dialog must still describe the
            // SAME worktree the dialog was raised for — re-check identity
            // against the freshest known list before deleting anything. A
            // direct `force: true` call made without a pending confirmation
            // (not the UI's dialog flow) is left alone below.
            guard worktrees.first(where: { $0.path == path })?.branch == confirmedBranch else {
                removal = .confirmationStale(worktreePath: path)
                return
            }
        }
        removal = .removing(worktreePath: path)
        do {
            _ = try await client.worktreeRemove(SupermuxWorktreeRemoveRequest(
                projectID: projectID,
                worktreePath: path,
                force: force
            ))
            removal = .idle
            await refetch()
        } catch {
            if !force, SupermuxWireErrorCode.code(from: error) == SupermuxWireErrorCode.dirtyWorktree {
                removal = .awaitingForceConfirmation(
                    worktreePath: path,
                    branch: worktrees.first(where: { $0.path == path })?.branch,
                    message: error.localizedDescription
                )
            } else {
                removal = .failed(worktreePath: path, message: error.localizedDescription)
            }
        }
    }

    /// Resets a parked removal state (force confirmation declined, or a
    /// failure acknowledged). A removal that is still on the wire is not
    /// interrupted.
    public func dismissRemoval() {
        if case .removing = removal { return }
        removal = .idle
    }

    private func refetch() async {
        do {
            let response = try await client.worktreesList(
                SupermuxWorktreesListRequest(projectID: projectID)
            )
            worktrees = response.worktrees
            hasLoaded = true
            lastErrorDescription = nil
            onWorktreesChanged?(projectID, worktrees)
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    /// Trims and blank-collapses an optional user-typed value so the wire
    /// never carries empty strings.
    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
