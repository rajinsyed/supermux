import Foundation
public import Observation

/// Main-actor domain model behind the supermux Changes panel.
///
/// Tracks the git status of one working directory through
/// ``SupermuxGitChangesService`` and exposes stage/unstage/commit/push/pull
/// operations for the UI. Views observe this model; all git I/O happens on
/// the underlying service actor.
///
/// Observation is opt-in and change-driven, not timed: callers pair
/// ``startObserving()`` with ``stopObserving()`` (typically from
/// `onAppear`/`onDisappear`). A ``SupermuxRepositoryWatcher`` yields an
/// `AsyncStream` of file-system changes under the working directory and the
/// model refreshes on each — no busy-loop polling. The observe task holds the
/// model weakly (so it never keeps an abandoned model alive) and is cancelled
/// in `deinit`, which ends the stream iteration and tears the FSEvents
/// watcher down even when ``stopObserving()`` was never called.
@MainActor
@Observable
public final class SupermuxChangesModel {
    /// The working directory whose git status is shown, normalized; `nil`
    /// when no directory is selected.
    public private(set) var directory: String?
    /// The latest git status for ``directory``.
    public private(set) var snapshot: SupermuxGitStatusSnapshot = .notARepository
    /// Whether a mutation (stage/commit/push/...) is in flight. The setter is
    /// module-internal so the AI-commit flow in
    /// `SupermuxChangesModel+AICommit.swift` can claim it.
    public internal(set) var isWorking: Bool = false
    /// The most recent mutation error, for UI display; cleared on success.
    /// Internal setter for the AI-commit extension.
    public internal(set) var lastError: String?
    /// The commit message bound to the commit box; cleared after a
    /// successful ``commit()``.
    public var commitMessage: String = ""
    /// ``commitMessage`` with surrounding whitespace/newlines stripped — the
    /// one emptiness/content test shared by ``commit()`` and the AI-commit
    /// entry points in `SupermuxChangesModel+AICommit.swift`.
    var trimmedCommitMessage: String {
        commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Whether AI commit-message generation is wired and a key is configured.
    /// Refreshed alongside the git status so the commit button can switch into
    /// "Generate & Commit" mode reactively.
    public private(set) var aiCommitConfigured: Bool = false
    /// Unpushed local commits (commits ahead of the remote / outgoing), newest
    /// first. Populated only while the section is expanded (see
    /// ``setHistoryExpanded(_:)``). The setter is module-internal so the
    /// commit-feed loaders in `SupermuxChangesModel+Sync.swift` can write it.
    public internal(set) var commits: [SupermuxGitCommit] = []
    /// Whether more unpushed commits exist beyond the loaded ``commits`` page.
    public internal(set) var hasMoreCommits = false
    /// Whether an unpushed-commit-log read is in flight; lets the UI distinguish
    /// "still loading" from "loaded and genuinely empty".
    public internal(set) var isLoadingCommits = false
    /// Authoritative count of unpushed (outgoing) commits, independent of
    /// whether the section is expanded: `ahead` with an upstream, otherwise a
    /// `rev-list` of local-only commits. Drives whether the Unpushed section is
    /// shown at all (hidden when `0`) and its header badge.
    public internal(set) var outgoingCount = 0
    /// Authoritative count of incoming (pullable) commits: `behind` with an
    /// upstream, otherwise `0`. Drives whether the Incoming section is shown.
    public internal(set) var incomingCount = 0
    /// Incoming commits (on the upstream but not in `HEAD` / pullable), newest
    /// first. Populated only while the Incoming section is expanded (see
    /// ``setIncomingExpanded(_:)``) and only meaningful with an upstream.
    public internal(set) var incomingCommits: [SupermuxGitCommit] = []
    /// Whether more incoming commits exist beyond the loaded
    /// ``incomingCommits`` page.
    public internal(set) var hasMoreIncoming = false
    /// Whether an incoming-commit-log read is in flight.
    public internal(set) var isLoadingIncoming = false

    let service: SupermuxGitChangesService
    /// Optional AI commit-message generator; `nil` disables AI commit.
    /// Module-internal for the AI-commit extension.
    @ObservationIgnored let commitGenerator: (any SupermuxAICommitMessaging)?
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    /// Identifies the directory a given refresh was issued for. Bumped on every
    /// directory change so an in-flight status read for the previous directory
    /// is discarded instead of overwriting the new directory's snapshot.
    /// Module-internal so the sync extension can guard its awaits the same way.
    @ObservationIgnored var directoryGeneration = 0
    /// True while a status read is awaiting; a request that arrives during one
    /// sets ``refreshPending`` rather than racing or being silently dropped.
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshPending = false
    /// The in-flight background `git fetch` as an awaitable handle (`nil` when no
    /// fetch is running — it is the single source of truth for "a fetch is in
    /// flight", replacing a separate boolean). Three consumers use it:
    /// ``fetchAndRefresh()`` serializes on it so two fetches never overlap; a
    /// user mutation (push/pull/commit) drains it before running git so a
    /// best-effort fetch and a visible mutation never update the same ref
    /// concurrently (the ref-lock error the auto-fetch was meant to avoid — an
    /// `isWorking`-only guard is one-directional); and a switched-to directory's
    /// fetch awaits it instead of skipping, so the new directory still fetches
    /// promptly rather than waiting out the timer. Module-internal for the sync
    /// extension.
    @ObservationIgnored var activeFetchTask: Task<Bool, Never>?
    /// Whether the Unpushed section is expanded; gates whether ``refresh()``
    /// reads the outgoing commit log, so a collapsed panel does no extra git work.
    @ObservationIgnored var commitsRequested = false
    /// Current outgoing commit-log page size; grown by ``loadMoreCommits()``.
    @ObservationIgnored var commitLimit = SupermuxChangesModel.commitPageSize
    /// Whether the Incoming section is expanded; gates the incoming commit-log read.
    @ObservationIgnored var incomingRequested = false
    /// Current incoming commit-log page size; grown by ``loadMoreIncoming()``.
    @ObservationIgnored var incomingLimit = SupermuxChangesModel.commitPageSize
    static let commitPageSize = 100

    /// Creates the model.
    /// - Parameters:
    ///   - service: Git status and mutation operations.
    ///   - commitGenerator: Optional AI commit-message generator enabling the
    ///     "Generate & Commit" flow when the message box is empty.
    public init(
        service: SupermuxGitChangesService,
        commitGenerator: (any SupermuxAICommitMessaging)? = nil
    ) {
        self.service = service
        self.commitGenerator = commitGenerator
    }

    deinit {
        // The view layer pairs start/stopObserving, but a window close can
        // tear the owning @State down without onDisappear ever firing.
        // Task.cancel() is thread-safe from a nonisolated deinit; cancelling
        // ends the stream iteration, which fires the watcher stream's
        // onTermination and stops the underlying FSEventStream.
        observeTask?.cancel()
    }

    /// Points the model at a new working directory.
    ///
    /// The path is tilde-expanded and standardized before comparison. When
    /// the directory actually changes, ``lastError`` and ``commitMessage``
    /// are cleared, the observation watcher is repointed (if observing), and a
    /// refresh is kicked off; the previous snapshot stays visible until the new
    /// status arrives to avoid flicker.
    /// - Parameter directory: New directory, or `nil` to clear.
    public func setDirectory(_ directory: String?) {
        let normalized = directory.map {
            (($0 as NSString).expandingTildeInPath as NSString).standardizingPath
        }
        guard normalized != self.directory else { return }
        self.directory = normalized
        directoryGeneration += 1
        lastError = nil
        commitMessage = ""
        // Drop the previous directory's commits; they reload for the new
        // directory on the next refresh when the section is still expanded.
        commits = []
        hasMoreCommits = false
        commitLimit = Self.commitPageSize
        incomingCommits = []
        hasMoreIncoming = false
        incomingLimit = Self.commitPageSize
        outgoingCount = 0
        incomingCount = 0
        if observeTask != nil {
            startObserving()
        } else {
            Task { [weak self] in
                await self?.refresh()
            }
        }
    }

    /// Re-reads the git status for the current directory.
    ///
    /// Only the status that still matches the current directory is written:
    /// the directory generation is captured before the await and re-checked
    /// after, so a slow read for a directory the user has since switched away
    /// from is discarded. If a refresh is requested while one is in flight, a
    /// single follow-up runs against the latest directory rather than being
    /// dropped.
    public func refresh() async {
        if isRefreshing {
            refreshPending = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshPending = false
            let generation = directoryGeneration
            if let directory {
                let result = await service.status(repoPath: directory)
                // Discard a read whose directory was switched away mid-flight,
                // and skip the helper chain entirely: every write below is
                // generation-guarded anyway, so running them for a stale
                // directory only issues three known-discarded git subprocesses
                // ahead of the pending current-directory iteration (which
                // `refreshPending` guarantees, since a directory switch always
                // requests a refresh while this one is in flight).
                guard generation == directoryGeneration else { continue }
                // Write-only-when-changed: `@Observable` fires on every
                // assignment, so an unconditional write would invalidate the
                // whole panel on each watcher-driven refresh even when the
                // status is identical.
                if snapshot != result { snapshot = result }
                // Refresh the always-visible outgoing/incoming counts (drive
                // section visibility), then reload the (small) commit sets while
                // their sections are expanded. Helpers gate on their own request
                // flags and discard stale results; see SupermuxChangesModel+Sync.swift.
                await updateSyncCounts(directory: directory, status: result, generation: generation)
                await loadOutgoingCommits(directory: directory, status: result, generation: generation)
                await loadIncomingCommits(directory: directory, status: result, generation: generation)
            } else {
                if snapshot != .notARepository { snapshot = .notARepository }
                if outgoingCount != 0 { outgoingCount = 0 }
                if incomingCount != 0 { incomingCount = 0 }
                clearOutgoingCommits()
                clearIncomingCommits()
            }
            // Cheap key-presence probe (reads one small file) so the commit
            // button reflects AI availability. Kept inside the loop so a refresh
            // requested during this await is still honored by `refreshPending`.
            if let commitGenerator {
                let configured = await commitGenerator.isConfigured()
                if aiCommitConfigured != configured { aiCommitConfigured = configured }
            }
        } while refreshPending
    }

    /// Minimum spacing between watcher-driven refreshes. Sustained churn (a
    /// build writing thousands of files) collapses to one refresh per window:
    /// the watcher stream buffers the newest pending signal, so a final
    /// catch-up refresh always lands after the churn stops.
    static let watcherRefreshInterval: Duration = .seconds(2)

    /// Starts observing the current directory for file-system changes and
    /// refreshes on each, cancelling any previous observation. Pair with
    /// ``stopObserving()`` from `onDisappear`.
    public func startObserving() {
        observeTask?.cancel()
        let directory = self.directory
        observeTask = Task { [weak self] in
            guard let directory else {
                await self?.refresh()
                return
            }
            // Start the FSEvents stream *before* the initial refresh
            // (`changes()` builds its stream eagerly), so a change landing
            // while that first status read runs is buffered and consumed —
            // refresh-then-watch would silently drop it.
            let watcher = SupermuxRepositoryWatcher(path: directory)
            let changes = watcher.changes()
            await self?.refresh()
            for await _ in changes {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.refresh()
                // Throttle: wait before consuming the next batch so build
                // churn cannot drive back-to-back git spawns (see
                // ``watcherRefreshInterval``). Cancellation ends the sleep
                // immediately and the loop exits via the cancelled stream.
                try? await Task.sleep(for: Self.watcherRefreshInterval)
            }
        }
    }

    /// Stops the observation started by ``startObserving()``.
    public func stopObserving() {
        observeTask?.cancel()
        observeTask = nil
    }

    /// Stages one change.
    /// - Parameter change: File to stage; for renames the old path is staged too.
    public func stage(_ change: SupermuxGitFileChange) async {
        await stage(changes: [change])
    }

    /// Stages the given changes with a single `git add` and a single refresh —
    /// the one mutation path for both the single-file row action and the
    /// Untracked section's Stage All, so N files never cost N add+status
    /// cycles. A failure is reported once for the whole batch (matching
    /// ``stageAll()``'s semantics). Empty input is a no-op.
    /// - Parameter changes: Files to stage; rename old paths are staged too.
    public func stage(changes: [SupermuxGitFileChange]) async {
        guard !changes.isEmpty else { return }
        await performMutation { repoPath, service in
            try await service.stage(repoPath: repoPath, paths: changes.flatMap(Self.paths(for:)))
        }
    }

    /// Unstages one change.
    /// - Parameter change: File to unstage; for renames the old path is reset too.
    public func unstage(_ change: SupermuxGitFileChange) async {
        await performMutation { repoPath, service in
            try await service.unstage(repoPath: repoPath, paths: Self.paths(for: change))
        }
    }

    /// Stages every change, including untracked files.
    public func stageAll() async {
        await performMutation { repoPath, service in
            try await service.stageAll(repoPath: repoPath)
        }
    }

    /// Unstages every staged change.
    public func unstageAll() async {
        await performMutation { repoPath, service in
            try await service.unstageAll(repoPath: repoPath)
        }
    }

    /// Discards a change: untracked files are deleted, tracked files are
    /// restored from HEAD.
    /// - Parameter change: File whose local modifications are thrown away.
    public func discard(_ change: SupermuxGitFileChange) async {
        await performMutation { repoPath, service in
            try await service.discard(repoPath: repoPath, change: change)
        }
    }

    /// Discards every change, restoring the working tree to `HEAD`: all staged
    /// and unstaged modifications to tracked files are reverted and all
    /// untracked files are deleted. Ignored files are left in place.
    public func discardAll() async {
        await performMutation { repoPath, service in
            try await service.discardAll(repoPath: repoPath)
        }
    }

    // MARK: - Commit history, sync & AI commit
    //
    // The Unpushed/Incoming commit feeds and the background auto-fetch live in
    // `SupermuxChangesModel+Sync.swift`; the AI "Generate & Commit" flow lives
    // in `SupermuxChangesModel+AICommit.swift`. Both keep this file focused on
    // status and working-tree mutations.

    /// Commits the staged changes using ``commitMessage``; clears the
    /// message on success. A blank message is a no-op.
    ///
    /// The message is cleared only when the commit's outcome applied to the
    /// panel's current directory — after a mid-commit workspace switch the
    /// clear would otherwise wipe whatever the user has typed for the *new*
    /// directory (`setDirectory` already reset the box for it).
    public func commit() async {
        let message = trimmedCommitMessage
        guard !message.isEmpty else { return }
        let applied = await performMutation { repoPath, service in
            try await service.commit(repoPath: repoPath, message: message)
        }
        if applied {
            commitMessage = ""
        }
    }

    /// Pushes the current branch, setting an upstream on the first push.
    public func push() async {
        let hasUpstream = snapshot.upstreamBranch != nil
        await performMutation { repoPath, service in
            try await service.push(repoPath: repoPath, hasUpstream: hasUpstream)
        }
    }

    /// Pulls from the current branch's upstream.
    public func pull() async {
        await performMutation { repoPath, service in
            try await service.pull(repoPath: repoPath)
        }
    }

    // MARK: - Stash

    /// Whether the stash menu should be offered at all: a repository that has
    /// something to stash or a stash to pop. Mirrors the discard-all button's
    /// "only when relevant" visibility so a clean repo with no stash stays
    /// uncluttered.
    public var isStashMenuAvailable: Bool {
        snapshot.isRepository
            && (snapshot.totalChangeCount > 0 || snapshot.stashEntryCount > 0)
    }

    /// Whether "Stash Changes" applies: tracked changes exist and the tree is
    /// not mid-conflict (`git stash` refuses unmerged paths).
    public var canStashTracked: Bool {
        snapshot.isRepository && snapshot.hasTrackedChanges && !snapshot.hasConflicts
    }

    /// Whether "Stash (Include Untracked)" applies: any change exists and the
    /// tree is not mid-conflict.
    public var canStashIncludingUntracked: Bool {
        snapshot.isRepository && snapshot.totalChangeCount > 0 && !snapshot.hasConflicts
    }

    /// Whether "Pop Stash" applies: a stash exists and the tree is not
    /// mid-conflict. A dirty tree is fine — git pops onto it when paths do not
    /// collide.
    public var canPopStash: Bool {
        snapshot.isRepository && snapshot.stashEntryCount > 0 && !snapshot.hasConflicts
    }

    /// Stashes working-tree changes, optionally including untracked files.
    /// - Parameter includeUntracked: Whether to also stash untracked files.
    public func stash(includeUntracked: Bool) async {
        await performMutation { repoPath, service in
            try await service.stash(repoPath: repoPath, includeUntracked: includeUntracked)
        }
    }

    /// Restores the most recent stash (`git stash pop`).
    public func popStash() async {
        await performMutation { repoPath, service in
            try await service.popStash(repoPath: repoPath)
        }
    }

    // MARK: - Internals

    /// Runs one mutation: guards against a missing directory and re-entrancy,
    /// flips ``isWorking``, records or clears ``lastError``, and always
    /// refreshes afterwards.
    ///
    /// `lastError` is only written when the panel still shows the directory the
    /// mutation ran against — a slow push/pull's outcome must not bleed onto
    /// another workspace's panel after a mid-flight switch (`setDirectory`
    /// bumps the generation and clears the new directory's error/message).
    /// - Returns: `true` when the work succeeded *and* its outcome applied to
    ///   the current directory, so callers can gate success side effects (like
    ///   clearing the commit box) without re-deriving the generation check.
    @discardableResult
    func performMutation(
        _ work: @MainActor (String, SupermuxGitChangesService) async throws -> Void
    ) async -> Bool {
        guard let directory, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        let generation = directoryGeneration
        // Claiming `isWorking` above blocks a new background fetch from starting;
        // draining any fetch already in flight closes the reverse race so the
        // mutation's git never updates a ref alongside the silent fetch.
        await drainActiveFetch()
        var succeeded = false
        do {
            try await work(directory, service)
            succeeded = true
        } catch {
            if generation == directoryGeneration {
                lastError = error.localizedDescription
            }
        }
        if succeeded, generation == directoryGeneration, lastError != nil {
            lastError = nil
        }
        await refresh()
        return succeeded && generation == directoryGeneration
    }

    /// Awaits every in-flight background fetch, including one that starts while
    /// waiting. A single-shot `await activeFetchTask?.value` can miss a fetch
    /// that replaced the handle during the await, letting a mutation's git run
    /// alongside it after all.
    func drainActiveFetch() async {
        while let task = activeFetchTask {
            _ = await task.value
            // Handle unchanged: that fetch finished (its owner clears the
            // handle imminently). A changed handle means a new fetch started
            // mid-drain — loop and await it too.
            if activeFetchTask == task { break }
        }
    }

    private static func paths(for change: SupermuxGitFileChange) -> [String] {
        var paths = [change.path]
        if let oldPath = change.oldPath {
            paths.append(oldPath)
        }
        return paths
    }
}
