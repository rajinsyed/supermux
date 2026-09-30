/// The git engine behind one ``SupermuxChangesModel``: where status is read
/// and where stage/commit/push run.
///
/// Two implementations exist:
/// - ``SupermuxLocalChangesBackend`` runs `git` on this Mac through
///   ``SupermuxGitChangesService`` (the desktop panel's original engine,
///   unchanged).
/// - ``SupermuxRemoteChangesBackend`` runs every operation on the Mac that
///   owns a mirrored workspace, over `mobile.supermux.changes.*`.
///
/// `repoPath` is the directory the model shows. The local backend runs git in
/// it; the remote backend uses it only as a fallback stale-view guard.
public protocol SupermuxChangesBackend: Sendable {
    /// Whether the repository lives on another Mac (its paths are not local).
    var isRemote: Bool { get }

    /// The repository's working-tree status.
    func status(repoPath: String) async -> SupermuxGitStatusSnapshot
    /// Stages the given repo-relative paths.
    func stage(repoPath: String, paths: [String]) async throws
    /// Stages every change, untracked files included.
    func stageAll(repoPath: String) async throws
    /// Unstages the given repo-relative paths.
    func unstage(repoPath: String, paths: [String]) async throws
    /// Unstages every staged change.
    func unstageAll(repoPath: String) async throws
    /// Throws away one change (untracked files are deleted).
    func discard(repoPath: String, change: SupermuxGitFileChange) async throws
    /// Restores the whole working tree to `HEAD`.
    func discardAll(repoPath: String) async throws
    /// Commits the staged changes.
    func commit(repoPath: String, message: String) async throws
    /// Pushes the current branch, setting an upstream on the first push.
    func push(repoPath: String, hasUpstream: Bool) async throws
    /// Pulls from the current branch's upstream.
    func pull(repoPath: String) async throws
    /// Stashes working-tree changes.
    func stash(repoPath: String, includeUntracked: Bool) async throws
    /// Restores the most recent stash.
    func popStash(repoPath: String) async throws
    /// Best-effort background fetch; `true` when remote-tracking refs may have moved.
    func fetch(repoPath: String) async -> Bool
    /// Unpushed commits on a branch that has no upstream.
    func unpushedCountWithoutUpstream(repoPath: String) async -> Int
    /// Outgoing (unpushed) commits, newest first.
    func unpushedCommits(repoPath: String, hasUpstream: Bool, limit: Int) async -> [SupermuxGitCommit]
    /// Incoming (pullable) commits, newest first.
    func incomingCommits(repoPath: String, limit: Int) async -> [SupermuxGitCommit]
    /// One file's diff on the staged (index) or working-tree side.
    func fileDiff(repoPath: String, path: String, oldPath: String?, staged: Bool) async -> SupermuxGitFileDiff
    /// The AI commit flow's change capture (empty when nothing changed).
    func uncommittedDiff(repoPath: String) async -> String
    /// Identity of untracked file contents (AI commit staleness guard).
    func untrackedContentDigest(repoPath: String) async -> String
    /// Identity of the full tracked diff (AI commit staleness guard).
    func trackedDiffDigest(repoPath: String) async -> String
    /// A signal per batch of repository changes, for as long as the stream is iterated.
    func changeSignals(repoPath: String) -> AsyncStream<Void>
}
