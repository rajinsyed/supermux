/// The Changes panel's engine for a repository on this Mac: a pass-through to
/// ``SupermuxGitChangesService`` (git on the local filesystem) plus the
/// FSEvents ``SupermuxRepositoryWatcher`` for change signals — exactly what the
/// model called directly before the backend seam existed.
public struct SupermuxLocalChangesBackend: SupermuxChangesBackend {
    /// The git engine every call forwards to.
    public let service: SupermuxGitChangesService

    /// Creates the backend.
    /// - Parameter service: The local git engine.
    public init(service: SupermuxGitChangesService) {
        self.service = service
    }

    public var isRemote: Bool { false }

    public func status(repoPath: String) async -> SupermuxGitStatusSnapshot {
        await service.status(repoPath: repoPath)
    }

    public func stage(repoPath: String, paths: [String]) async throws {
        try await service.stage(repoPath: repoPath, paths: paths)
    }

    public func stageAll(repoPath: String) async throws {
        try await service.stageAll(repoPath: repoPath)
    }

    public func unstage(repoPath: String, paths: [String]) async throws {
        try await service.unstage(repoPath: repoPath, paths: paths)
    }

    public func unstageAll(repoPath: String) async throws {
        try await service.unstageAll(repoPath: repoPath)
    }

    public func discard(repoPath: String, change: SupermuxGitFileChange) async throws {
        try await service.discard(repoPath: repoPath, change: change)
    }

    public func discardAll(repoPath: String) async throws {
        try await service.discardAll(repoPath: repoPath)
    }

    public func commit(repoPath: String, message: String) async throws {
        try await service.commit(repoPath: repoPath, message: message)
    }

    public func push(repoPath: String, hasUpstream: Bool) async throws {
        _ = try await service.push(repoPath: repoPath, hasUpstream: hasUpstream)
    }

    public func pull(repoPath: String) async throws {
        _ = try await service.pull(repoPath: repoPath)
    }

    public func stash(repoPath: String, includeUntracked: Bool) async throws {
        _ = try await service.stash(repoPath: repoPath, includeUntracked: includeUntracked)
    }

    public func popStash(repoPath: String) async throws {
        _ = try await service.popStash(repoPath: repoPath)
    }

    public func fetch(repoPath: String) async -> Bool {
        await service.fetch(repoPath: repoPath)
    }

    public func unpushedCountWithoutUpstream(repoPath: String) async -> Int {
        await service.unpushedCountWithoutUpstream(repoPath: repoPath)
    }

    public func unpushedCommits(repoPath: String, hasUpstream: Bool, limit: Int) async -> [SupermuxGitCommit] {
        await service.unpushedCommits(repoPath: repoPath, hasUpstream: hasUpstream, limit: limit)
    }

    public func incomingCommits(repoPath: String, limit: Int) async -> [SupermuxGitCommit] {
        await service.incomingCommits(repoPath: repoPath, limit: limit)
    }

    public func fileDiff(repoPath: String, path: String, oldPath: String?, staged: Bool) async -> SupermuxGitFileDiff {
        await service.fileDiff(repoPath: repoPath, path: path, oldPath: oldPath, staged: staged)
    }

    public func uncommittedDiff(repoPath: String) async -> String {
        await service.uncommittedDiff(repoPath: repoPath)
    }

    public func untrackedContentDigest(repoPath: String) async -> String {
        await service.untrackedContentDigest(repoPath: repoPath)
    }

    public func trackedDiffDigest(repoPath: String) async -> String {
        await service.trackedDiffDigest(repoPath: repoPath)
    }

    public func changeSignals(repoPath: String) -> AsyncStream<Void> {
        SupermuxRepositoryWatcher(path: repoPath).changes()
    }
}
