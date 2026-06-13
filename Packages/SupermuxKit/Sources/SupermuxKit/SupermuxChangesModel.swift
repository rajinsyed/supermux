import Foundation
public import Observation

/// Main-actor domain model behind the supermux Changes panel.
///
/// Tracks the git status of one working directory through
/// ``SupermuxGitChangesService`` and exposes stage/unstage/commit/push/pull
/// operations for the UI. Views observe this model; all git I/O happens on
/// the underlying service actor.
///
/// Polling is opt-in: callers pair ``startPolling()`` with ``stopPolling()``
/// (typically from `onAppear`/`onDisappear`). The poll task holds the model
/// weakly, so an abandoned model deinitializes and its loop exits on the next
/// iteration rather than leaking.
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

    private let service: SupermuxGitChangesService
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false

    /// Creates the model.
    /// - Parameter service: Git status and mutation operations.
    public init(service: SupermuxGitChangesService) {
        self.service = service
    }

    /// Points the model at a new working directory.
    ///
    /// The path is tilde-expanded and standardized before comparison. When
    /// the directory actually changes, ``lastError`` and ``commitMessage``
    /// are cleared and a refresh is kicked off; the previous snapshot stays
    /// visible until the new status arrives to avoid flicker.
    /// - Parameter directory: New directory, or `nil` to clear.
    public func setDirectory(_ directory: String?) {
        let normalized = directory.map {
            (($0 as NSString).expandingTildeInPath as NSString).standardizingPath
        }
        guard normalized != self.directory else { return }
        self.directory = normalized
        lastError = nil
        commitMessage = ""
        Task { [weak self] in
            await self?.refresh()
        }
    }

    /// Re-reads the git status for the current directory.
    ///
    /// Overlapping calls (e.g. poll tick during a manual refresh) are
    /// coalesced: a refresh already in flight makes this a no-op.
    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let directory else {
            snapshot = .notARepository
            return
        }
        snapshot = await service.status(repoPath: directory)
    }

    /// Starts refreshing the status every 3 seconds, cancelling any
    /// previous poll. Pair with ``stopPolling()`` from `onDisappear`.
    public func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Stops the periodic refresh started by ``startPolling()``.
    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
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
