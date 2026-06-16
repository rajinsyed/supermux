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
/// model weakly, so an abandoned model deinitializes and its stream iteration
/// ends rather than leaking.
@MainActor
@Observable
public final class SupermuxChangesModel {
    /// The working directory whose git status is shown, normalized; `nil`
    /// when no directory is selected.
    public private(set) var directory: String?
    /// The latest git status for ``directory``.
    public private(set) var snapshot: SupermuxGitStatusSnapshot = .notARepository
    /// Whether a mutation (stage/commit/push/...) is in flight.
    public private(set) var isWorking: Bool = false
    /// The most recent mutation error, for UI display; cleared on success.
    public private(set) var lastError: String?
    /// The commit message bound to the commit box; cleared after a
    /// successful ``commit()``.
    public var commitMessage: String = ""
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
    @ObservationIgnored private let commitGenerator: (any SupermuxAICommitMessaging)?
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
    /// True while a background `git fetch` is in flight. Gates the auto-fetch in
    /// ``fetchAndRefresh()`` so two fetches never overlap; combined with the
    /// `isWorking` check it also keeps the silent fetch from racing a
    /// user-initiated push/pull (whose own fetch would otherwise hit a ref lock
    /// and surface a spurious error). Module-internal for the sync extension.
    @ObservationIgnored var isFetching = false
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
                // Discard a read whose directory was switched away mid-flight.
                if generation == directoryGeneration {
                    snapshot = result
                }
                // Refresh the always-visible outgoing/incoming counts (drive
                // section visibility), then reload the (small) commit sets while
                // their sections are expanded. Helpers gate on their own request
                // flags and discard stale results; see SupermuxChangesModel+Sync.swift.
                await updateSyncCounts(directory: directory, status: result, generation: generation)
                await loadOutgoingCommits(directory: directory, status: result, generation: generation)
                await loadIncomingCommits(directory: directory, status: result, generation: generation)
            } else {
                snapshot = .notARepository
                outgoingCount = 0
                incomingCount = 0
                clearOutgoingCommits()
                clearIncomingCommits()
            }
            // Cheap key-presence probe (reads one small file) so the commit
            // button reflects AI availability. Kept inside the loop so a refresh
            // requested during this await is still honored by `refreshPending`.
            if let commitGenerator {
                aiCommitConfigured = await commitGenerator.isConfigured()
            }
        } while refreshPending
    }

    /// Starts observing the current directory for file-system changes and
    /// refreshes on each, cancelling any previous observation. Pair with
    /// ``stopObserving()`` from `onDisappear`.
    public func startObserving() {
        observeTask?.cancel()
        let directory = self.directory
        observeTask = Task { [weak self] in
            await self?.refresh()
            guard let directory else { return }
            let watcher = SupermuxRepositoryWatcher(path: directory)
            for await _ in watcher.changes() {
                if Task.isCancelled { return }
                await self?.refresh()
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
        await performMutation { repoPath, service in
            try await service.stage(repoPath: repoPath, paths: Self.paths(for: change))
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

    // MARK: - Commit history & sync
    //
    // The Unpushed/Incoming commit feeds and the background auto-fetch live in
    // `SupermuxChangesModel+Sync.swift` to keep this file focused on status and
    // working-tree mutations.

    /// Commits the staged changes using ``commitMessage``; clears the
    /// message on success. A blank message is a no-op.
    public func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        await performMutation { [weak self] repoPath, service in
            try await service.commit(repoPath: repoPath, message: message)
            self?.commitMessage = ""
        }
    }

    /// Whether the commit button is in AI mode: the message box is empty, AI is
    /// configured, and there is at least one change to commit.
    public var isAICommitMode: Bool {
        commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && aiCommitConfigured
            && snapshot.totalChangeCount > 0
    }

    /// Whether the commit button should be enabled. With a typed message it
    /// requires staged changes; with an empty message it requires AI mode.
    public var canCommit: Bool {
        guard !isWorking, snapshot.isRepository else { return false }
        if commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return isAICommitMode
        }
        return !snapshot.staged.isEmpty
    }

    /// Localized title for the commit button, reflecting AI vs. normal mode.
    public var commitButtonTitle: String {
        isAICommitMode
            ? String(localized: "supermux.changes.ai.generateAndCommit", defaultValue: "Generate & Commit")
            : String(localized: "supermux.changes.commit", defaultValue: "Commit")
    }

    /// Commit entry point used by the button: a typed message commits staged
    /// changes directly; an empty message triggers the AI flow
    /// (``generateAndCommit()``).
    public func performCommit() async {
        if commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await generateAndCommit()
        } else {
            await commit()
        }
    }

    private enum AICommitOutcome {
        case committed
        case failed(String)
    }

    /// Generates a commit message with AI, then stages everything and commits.
    ///
    /// Atomic by construction: the message is produced from a *non-mutating*
    /// diff (``SupermuxGitChangesService/uncommittedDiff(repoPath:)``), so a
    /// missing key, an offline gateway, or an empty diff returns without ever
    /// touching the index — `git add -A` runs only once a message is in hand.
    /// All network/git work happens in ``runAICommit(generator:directory:)``;
    /// the resulting state is applied only if the user has not switched
    /// workspaces during the (multi-second) AI call, so a slow commit's
    /// outcome never bleeds onto another workspace's panel.
    private func generateAndCommit() async {
        guard let commitGenerator, let directory, !isWorking,
              snapshot.totalChangeCount > 0 else { return }
        let generation = directoryGeneration
        isWorking = true
        defer { isWorking = false }
        let outcome = await runAICommit(generator: commitGenerator, directory: directory)
        // Drop the result if the user switched the focused workspace mid-flight.
        guard generation == directoryGeneration else { return }
        switch outcome {
        case .committed:
            commitMessage = ""
            lastError = nil
        case .failed(let message):
            lastError = message
        }
        await refresh()
    }

    /// Runs the AI commit pipeline against `directory`, returning the outcome
    /// without mutating any `@Published` model state (the caller applies it).
    private func runAICommit(
        generator: any SupermuxAICommitMessaging,
        directory: String
    ) async -> AICommitOutcome {
        guard await generator.isConfigured() else {
            return .failed(SupermuxAIError.notConfigured.localizedDescription)
        }
        let diff = await service.uncommittedDiff(repoPath: directory)
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(String(
                localized: "supermux.changes.ai.nothingToCommit",
                defaultValue: "Nothing to commit."
            ))
        }
        guard let message = await generator.generateMessage(forDiff: diff) else {
            return .failed(String(
                localized: "supermux.changes.ai.generateFailed",
                defaultValue: "Couldn’t generate a commit message. Check your AI settings."
            ))
        }
        do {
            try await service.stageAll(repoPath: directory)
            try await service.commit(repoPath: directory, message: message)
            return .committed
        } catch {
            return .failed(error.localizedDescription)
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
    private func performMutation(
        _ work: @MainActor (String, SupermuxGitChangesService) async throws -> Void
    ) async {
        guard let directory, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await work(directory, service)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    private static func paths(for change: SupermuxGitFileChange) -> [String] {
        var paths = [change.path]
        if let oldPath = change.oldPath {
            paths.append(oldPath)
        }
        return paths
    }
}
