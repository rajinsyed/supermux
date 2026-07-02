import Foundation

/// Commit-feed (Unpushed/Incoming) loading and the background auto-fetch for
/// ``SupermuxChangesModel``.
///
/// Split out of `SupermuxChangesModel.swift` so the core model file stays
/// focused on status and working-tree mutations. The Unpushed feed lists
/// outgoing commits (`@{upstream}..HEAD`, what a push would send); the Incoming
/// feed lists pullable commits (`HEAD..@{upstream}`, what a pull would bring).
/// Both reload on each ``SupermuxChangesModel/refresh()`` while their section is
/// expanded and discard results whose directory was switched away mid-flight.
extension SupermuxChangesModel {

    // MARK: - Section counts

    /// Refreshes ``outgoingCount`` / ``incomingCount`` from the latest status.
    ///
    /// Incoming is `behind` (pullable commits require an upstream). Outgoing is
    /// `ahead` when there is an upstream; otherwise a never-pushed branch still
    /// has unpushed commits that `ahead` cannot see, so it falls back to a cheap
    /// `rev-list` count (the only extra git call, and only without an upstream).
    /// These counts drive section visibility, so they are computed on every
    /// refresh regardless of whether either section is expanded.
    func updateSyncCounts(
        directory: String, status: SupermuxGitStatusSnapshot, generation: Int
    ) async {
        let incoming = status.upstreamBranch != nil ? status.behind : 0
        let outgoing: Int
        if status.upstreamBranch != nil {
            outgoing = status.ahead
        } else if status.isRepository {
            outgoing = await service.unpushedCountWithoutUpstream(repoPath: directory)
        } else {
            outgoing = 0
        }
        guard generation == directoryGeneration else { return }
        // Write-only-when-changed: `@Observable` fires on every assignment, so
        // unconditional writes would invalidate the whole panel each refresh.
        if incomingCount != incoming { incomingCount = incoming }
        if outgoingCount != outgoing { outgoingCount = outgoing }
    }

    // MARK: - Outgoing (Unpushed)

    /// Expands or collapses the Unpushed (outgoing) section.
    ///
    /// Expanding marks the log as requested, resets paging, and refreshes so the
    /// commits load (and stay fresh on later refreshes). Collapsing stops the
    /// log from being read and clears the loaded commits, so a collapsed panel
    /// does no extra git work.
    /// - Parameter expanded: Whether the section is now expanded.
    public func setHistoryExpanded(_ expanded: Bool) async {
        if expanded {
            guard !commitsRequested else { return }
            commitsRequested = true
            commitLimit = Self.commitPageSize
            // Show the loading state immediately; if a refresh is already in
            // flight this expand only sets `refreshPending`, so the flag would
            // otherwise lag a frame behind.
            isLoadingCommits = true
            await refresh()
        } else {
            commitsRequested = false
            clearOutgoingCommits()
        }
    }

    /// Loads the next page of outgoing commits; a no-op when collapsed or when
    /// no further commits exist.
    public func loadMoreCommits() async {
        guard commitsRequested, hasMoreCommits else { return }
        commitLimit += Self.commitPageSize
        isLoadingCommits = true
        await refresh()
    }

    /// Reloads the outgoing (unpushed) commit set for the current refresh.
    ///
    /// Gated on the section being expanded. With an upstream and nothing ahead
    /// the range is provably empty, so the `git log` is skipped. Reads one extra
    /// commit to detect further pages, and only writes results that still match
    /// the issuing directory and an expanded section.
    func loadOutgoingCommits(
        directory: String, status: SupermuxGitStatusSnapshot, generation: Int
    ) async {
        guard commitsRequested else { return }
        guard status.isRepository else {
            clearOutgoingCommits()
            return
        }
        let hasUpstream = status.upstreamBranch != nil
        if hasUpstream, status.ahead == 0 {
            // Same guard as the loaded path below: a stale generation must not
            // touch the new directory's list or spinner, and the equality-gated
            // clear helper keeps the steady-state empty refresh write-free.
            // (`commitsRequested` cannot have flipped since the entry guard —
            // no suspension point in between — but mirror the loaded path.)
            if generation == directoryGeneration, commitsRequested {
                clearOutgoingCommits()
            }
            return
        }
        isLoadingCommits = true
        let loaded = await service.unpushedCommits(
            repoPath: directory, hasUpstream: hasUpstream, limit: commitLimit + 1
        )
        if generation == directoryGeneration, commitsRequested {
            hasMoreCommits = loaded.count > commitLimit
            commits = Array(loaded.prefix(commitLimit))
        }
        // Only clear loading for the current directory: a stale load finishing
        // after a workspace switch must not flip the new directory's spinner off
        // (which would flash "No unpushed commits" before its own load lands).
        if generation == directoryGeneration {
            isLoadingCommits = false
        }
    }

    /// Clears the loaded outgoing commits and their loading/paging flags.
    /// Write-only-when-changed so the steady-state refresh of an empty section
    /// never invalidates observers.
    func clearOutgoingCommits() {
        if !commits.isEmpty { commits = [] }
        if hasMoreCommits { hasMoreCommits = false }
        if isLoadingCommits { isLoadingCommits = false }
    }

    // MARK: - Incoming

    /// Expands or collapses the Incoming section. Mirrors
    /// ``setHistoryExpanded(_:)`` for the pullable-commit feed.
    /// - Parameter expanded: Whether the section is now expanded.
    public func setIncomingExpanded(_ expanded: Bool) async {
        if expanded {
            guard !incomingRequested else { return }
            incomingRequested = true
            incomingLimit = Self.commitPageSize
            isLoadingIncoming = true
            await refresh()
        } else {
            incomingRequested = false
            clearIncomingCommits()
        }
    }

    /// Loads the next page of incoming commits; a no-op when collapsed or when
    /// no further commits exist.
    public func loadMoreIncoming() async {
        guard incomingRequested, hasMoreIncoming else { return }
        incomingLimit += Self.commitPageSize
        isLoadingIncoming = true
        await refresh()
    }

    /// Reloads the incoming (pullable) commit set for the current refresh.
    ///
    /// Gated on the section being expanded. Unlike the outgoing feed there is no
    /// remotes fallback: with no upstream — or when the branch is not behind —
    /// the `HEAD..@{upstream}` range is empty, so the `git log` is skipped.
    func loadIncomingCommits(
        directory: String, status: SupermuxGitStatusSnapshot, generation: Int
    ) async {
        guard incomingRequested else { return }
        guard status.isRepository, status.upstreamBranch != nil, status.behind > 0 else {
            // See loadOutgoingCommits' early-exit: generation-guarded so a
            // stale result cannot clear the new directory's spinner, with the
            // equality-gated clear helper avoiding steady-state writes.
            if generation == directoryGeneration, incomingRequested {
                clearIncomingCommits()
            }
            return
        }
        isLoadingIncoming = true
        let loaded = await service.incomingCommits(
            repoPath: directory, limit: incomingLimit + 1
        )
        if generation == directoryGeneration, incomingRequested {
            hasMoreIncoming = loaded.count > incomingLimit
            incomingCommits = Array(loaded.prefix(incomingLimit))
        }
        // See loadOutgoingCommits: only the current directory clears the spinner.
        if generation == directoryGeneration {
            isLoadingIncoming = false
        }
    }

    /// Clears the loaded incoming commits and their loading/paging flags.
    /// Write-only-when-changed, mirroring ``clearOutgoingCommits()``.
    func clearIncomingCommits() {
        if !incomingCommits.isEmpty { incomingCommits = [] }
        if hasMoreIncoming { hasMoreIncoming = false }
        if isLoadingIncoming { isLoadingIncoming = false }
    }

    // MARK: - Auto-fetch

    /// Refreshes local status immediately, then runs a best-effort background
    /// `git fetch` and refreshes again when it updates the remote-tracking refs
    /// — so the behind/incoming counts reflect commits pushed elsewhere (e.g. a
    /// merged worktree) without the user pulling blindly.
    ///
    /// Fetch failures are swallowed (offline, no remote, missing credential);
    /// they never set ``lastError``, which is reserved for user-initiated
    /// mutations such as push/pull. Driven by the panel on appear, on directory
    /// change, on a slow timer, and from the manual refresh button — never from
    /// the file-system watcher, so the fetch's own writes under `.git` cannot
    /// trigger another fetch.
    ///
    /// The fetch is skipped while a user mutation is in flight (``isWorking``),
    /// and a user mutation conversely drains any in-flight fetch before running
    /// git (see ``SupermuxChangesModel/performMutation`` /
    /// ``SupermuxChangesModel/generateAndCommit``), so the silent fetch and a
    /// visible push/pull never update the same ref at once (a ref-lock error).
    /// Concurrent fetches serialize on ``activeFetchTask`` rather than being
    /// dropped: a fetch for a just-switched-to directory awaits the previous
    /// one (which is not cancellation-aware) and then runs, so the new
    /// directory's counts are not left stale until the next timer tick. The
    /// refresh after the fetch runs regardless of this fetch's own outcome: a
    /// sibling window or worktree sharing the remote may have advanced the
    /// tracking refs meanwhile, and the local `git status` picks that up.
    public func fetchAndRefresh() async {
        await refresh()
        // No fetch for a non-repository (it would just spawn a failing `git
        // fetch` on every tick) or while a user mutation owns the model.
        guard directory != nil, snapshot.isRepository, !isWorking else { return }
        // Drain any in-flight fetch (rather than skip ours) so a workspace
        // switch still fetches the new directory promptly instead of waiting out
        // the timer. `drainActiveFetch` also catches a fetch that replaces the
        // handle mid-drain, so two fetches never overlap on the same remote.
        await drainActiveFetch()
        // Re-check after the await: a mutation may have begun or the workspace
        // may have become a non-repository while we waited.
        guard let directory, snapshot.isRepository, !isWorking else { return }
        let generation = directoryGeneration
        let task = Task { await service.fetch(repoPath: directory) }
        activeFetchTask = task
        // Clear only if a later fetch has not replaced us (`Task` is Equatable by
        // identity), so a racing fetch's handle is never clobbered to nil.
        defer { if activeFetchTask == task { activeFetchTask = nil } }
        _ = await task.value
        // Drop the follow-up if the user switched workspaces during the fetch.
        guard generation == directoryGeneration else { return }
        await refresh()
    }
}
