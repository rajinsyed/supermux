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
    /// Unpushed local commits (commits ahead of the remote), newest first.
    /// Populated only while the section is expanded (see
    /// ``setHistoryExpanded(_:)``).
    public private(set) var commits: [SupermuxGitCommit] = []
    /// Whether more unpushed commits exist beyond the loaded ``commits`` page.
    public private(set) var hasMoreCommits = false
    /// Whether a commit-log read is in flight; lets the UI distinguish
    /// "still loading" from "loaded and genuinely empty".
    public private(set) var isLoadingCommits = false

    private let service: SupermuxGitChangesService
    /// Optional AI commit-message generator; `nil` disables AI commit.
    @ObservationIgnored private let commitGenerator: (any SupermuxAICommitMessaging)?
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    /// Identifies the directory a given refresh was issued for. Bumped on every
    /// directory change so an in-flight status read for the previous directory
    /// is discarded instead of overwriting the new directory's snapshot.
    @ObservationIgnored private var directoryGeneration = 0
    /// True while a status read is awaiting; a request that arrives during one
    /// sets ``refreshPending`` rather than racing or being silently dropped.
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshPending = false
    /// Whether the history section is expanded; gates whether ``refresh()``
    /// reads the commit log, so a collapsed panel does no extra git work.
    @ObservationIgnored private var commitsRequested = false
    /// Current commit-log page size; grown by ``loadMoreCommits()``.
    @ObservationIgnored private var commitLimit = SupermuxChangesModel.commitPageSize
    private static let commitPageSize = 100

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
                // The unpushed set is small, so reload it on each refresh while
                // expanded — that catches every change (commit, push, fetch,
                // amend, force-push) without a fragile cache key. The one cheap
                // shortcut: with an upstream and nothing ahead, the range is
                // provably empty, so skip the `git log` entirely.
                if commitsRequested, result.isRepository {
                    let hasUpstream = result.upstreamBranch != nil
                    if hasUpstream, result.ahead == 0 {
                        if generation == directoryGeneration, commitsRequested {
                            commits = []
                            hasMoreCommits = false
                        }
                        isLoadingCommits = false
                    } else {
                        isLoadingCommits = true
                        // Read one extra commit to detect whether more pages exist.
                        let loaded = await service.unpushedCommits(
                            repoPath: directory,
                            hasUpstream: hasUpstream,
                            limit: commitLimit + 1
                        )
                        // Discard the result if the directory changed or the
                        // section was collapsed while the read was in flight.
                        if generation == directoryGeneration, commitsRequested {
                            hasMoreCommits = loaded.count > commitLimit
                            commits = Array(loaded.prefix(commitLimit))
                        }
                        isLoadingCommits = false
                    }
                } else if commitsRequested {
                    // Expanded but not a repository: nothing to show.
                    commits = []
                    hasMoreCommits = false
                    isLoadingCommits = false
                }
            } else {
                snapshot = .notARepository
                commits = []
                hasMoreCommits = false
                isLoadingCommits = false
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

    // MARK: - History

    /// Expands or collapses the commit-history section.
    ///
    /// Expanding marks the log as requested, resets paging, and refreshes so the
    /// commits load (and stay fresh on later refreshes). Collapsing stops the
    /// log from being read and clears the loaded commits, so a collapsed panel
    /// does no extra git work.
    /// - Parameter expanded: Whether the history section is now expanded.
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
            commits = []
            hasMoreCommits = false
            isLoadingCommits = false
        }
    }

    /// Loads the next page of commit history; a no-op when collapsed or when no
    /// further commits exist.
    public func loadMoreCommits() async {
        guard commitsRequested, hasMoreCommits else { return }
        commitLimit += Self.commitPageSize
        isLoadingCommits = true
        await refresh()
    }

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
