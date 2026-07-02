import Testing
@testable import SupermuxKit

/// Unit tests for ``SupermuxRepositoryWatcher``'s event-batch filtering: git's
/// own bookkeeping noise (lock files, object writes, reflogs, `FETCH_HEAD`)
/// must not re-trigger the refresh whose spawned git produced it, while real
/// state changes (index, `HEAD`, refs, working-tree files) always deliver.
struct SupermuxRepositoryWatcherTests {

    // MARK: - Noise classification

    @Test func gitBookkeepingPathsAreNoise() {
        #expect(SupermuxRepositoryWatcher.isGitNoise(path: "/repo/.git/index.lock"))
        #expect(SupermuxRepositoryWatcher.isGitNoise(path: "/repo/.git/refs/remotes/origin/main.lock"))
        #expect(SupermuxRepositoryWatcher.isGitNoise(path: "/repo/.git/objects/ab/cdef0123456789"))
        #expect(SupermuxRepositoryWatcher.isGitNoise(path: "/repo/.git/objects/pack/pack-1234.pack"))
        #expect(SupermuxRepositoryWatcher.isGitNoise(path: "/repo/.git/FETCH_HEAD"))
        #expect(SupermuxRepositoryWatcher.isGitNoise(path: "/repo/.git/logs/HEAD"))
        #expect(SupermuxRepositoryWatcher.isGitNoise(path: "/repo/.git/logs/refs/heads/main"))
    }

    /// Real git state changes — what an external `git add`/`commit`/`checkout`
    /// writes — must pass through so the panel refreshes.
    @Test func gitStateChangePathsAreNotNoise() {
        #expect(!SupermuxRepositoryWatcher.isGitNoise(path: "/repo/.git/index"))
        #expect(!SupermuxRepositoryWatcher.isGitNoise(path: "/repo/.git/HEAD"))
        #expect(!SupermuxRepositoryWatcher.isGitNoise(path: "/repo/.git/refs/heads/main"))
        #expect(!SupermuxRepositoryWatcher.isGitNoise(path: "/repo/.git/packed-refs"))
    }

    /// Working-tree paths are never noise, even when they resemble git names.
    @Test func workingTreePathsAreNotNoise() {
        #expect(!SupermuxRepositoryWatcher.isGitNoise(path: "/repo/src/main.swift"))
        #expect(!SupermuxRepositoryWatcher.isGitNoise(path: "/repo/build/output.lock"))
        #expect(!SupermuxRepositoryWatcher.isGitNoise(path: "/repo/docs/objects/notes.md"))
        // A submodule-style nested working file under a directory named logs.
        #expect(!SupermuxRepositoryWatcher.isGitNoise(path: "/repo/logs/app.log"))
    }

    // MARK: - Batch delivery

    @Test func allNoiseBatchIsDropped() {
        #expect(!SupermuxRepositoryWatcher.shouldDeliver(eventPaths: [
            "/repo/.git/index.lock",
            "/repo/.git/objects/ab/cdef",
            "/repo/.git/logs/HEAD",
        ]))
    }

    @Test func mixedBatchIsDelivered() {
        #expect(SupermuxRepositoryWatcher.shouldDeliver(eventPaths: [
            "/repo/.git/index.lock",
            "/repo/src/main.swift",
        ]))
    }

    @Test func indexAndRefWritesAreDelivered() {
        #expect(SupermuxRepositoryWatcher.shouldDeliver(eventPaths: ["/repo/.git/index"]))
        #expect(SupermuxRepositoryWatcher.shouldDeliver(eventPaths: ["/repo/.git/refs/heads/main"]))
        #expect(SupermuxRepositoryWatcher.shouldDeliver(eventPaths: ["/repo/.git/packed-refs"]))
        #expect(SupermuxRepositoryWatcher.shouldDeliver(eventPaths: ["/repo/.git/HEAD"]))
    }

    /// Defensive: an empty batch (paths unavailable) must deliver rather than
    /// silently starve the refresh.
    @Test func emptyBatchIsDelivered() {
        #expect(SupermuxRepositoryWatcher.shouldDeliver(eventPaths: []))
    }
}
