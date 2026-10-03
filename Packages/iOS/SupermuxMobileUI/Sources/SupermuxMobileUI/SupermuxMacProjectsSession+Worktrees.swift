import Foundation
import SupermuxMobileCore
import SupermuxMobileKit

/// The worktree half of one Mac's session: the stores behind expanded
/// projects' nested rows, their pause/resume across navigation pushes, and
/// the unopened-worktree counts shown on collapsed rows.
extension SupermuxMacProjectsSession {
    /// Builds a worktrees store for one of this Mac's projects, or `nil`
    /// while disconnected or without `supermux.worktrees.v1`. The store feeds
    /// the row's count after each fetch — generation-guarded, so a store of a
    /// replaced session can never overwrite the new session's counts.
    /// - Parameter projectID: The project's Mac-local UUID string.
    func makeWorktreesStore(forProjectID projectID: String) -> SupermuxMobileWorktreesStore? {
        guard let client, let capabilities, capabilities.supportsWorktrees else { return nil }
        let generation = generation
        return SupermuxMobileWorktreesStore(
            client: client,
            capabilities: capabilities,
            projectID: projectID,
            onWorktreesChanged: { [weak self] projectID, worktrees in
                guard let self, self.generation == generation else { return }
                self.recordWorktrees(worktrees, forProjectID: projectID)
            }
        )
    }

    /// Records a project's fresh worktree list as its UNOPENED count.
    func recordWorktrees(_ worktrees: [SupermuxWorktreeDTO], forProjectID projectID: String) {
        let count = SupermuxWorktreeRowSnapshot.unopenedRows(from: worktrees).count
        if worktreeCounts[projectID] != count {
            worktreeCounts[projectID] = count
        }
    }

    /// The nested-worktree slice for one expanded project.
    func nestedWorktrees(forProjectID projectID: String) -> SupermuxProjectNestedWorktrees {
        guard let store = worktreeSessions[projectID]?.store else { return .unavailable }
        guard store.hasLoaded else { return .loading }
        return .loaded(SupermuxWorktreeRowSnapshot.unopenedRows(from: store.worktrees))
    }

    /// Starts an expanded project's worktree session (no-op while
    /// disconnected or without `supermux.worktrees.v1`).
    func startWorktreeSession(forProjectID projectID: String) {
        guard worktreeSessions[projectID] == nil,
              let store = makeWorktreesStore(forProjectID: projectID) else { return }
        let task = Task { await store.run() }
        worktreeSessions[projectID] = WorktreeSession(store: store, task: task)
    }

    func endWorktreeSession(forProjectID projectID: String) {
        worktreeSessions.removeValue(forKey: projectID)?.task?.cancel()
    }

    /// Pauses every worktree loop WITHOUT dropping its store (m6-f3).
    func pauseWorktreeSessionLoops() {
        for (projectID, session) in worktreeSessions where session.task != nil {
            session.task?.cancel()
            worktreeSessions[projectID]?.predecessor = session.task
            worktreeSessions[projectID]?.task = nil
        }
    }

    /// Restarts paused worktree loops, each chained behind its cancelled
    /// predecessor's exit.
    func resumeWorktreeSessionLoops() {
        for (projectID, session) in worktreeSessions where session.task == nil {
            let store = session.store
            let previous = session.predecessor
            worktreeSessions[projectID]?.predecessor = nil
            worktreeSessions[projectID]?.task = Task {
                await previous?.value
                guard !Task.isCancelled else { return }
                await store.run()
            }
        }
    }

    /// Ends worktree sessions of projects this Mac no longer lists.
    func pruneWorktreeSessions(keepingProjectIDs projectIDs: [String]) {
        let known = Set(projectIDs)
        for projectID in worktreeSessions.keys where !known.contains(projectID) {
            endWorktreeSession(forProjectID: projectID)
        }
    }

    func endAllWorktreeSessions() {
        for session in worktreeSessions.values {
            session.task?.cancel()
        }
        worktreeSessions.removeAll()
    }

    /// One-shot count seeding for collapsed projects, at most once per
    /// project per session, mirroring the Mac's eager refresh at load.
    func seedWorktreeCounts(forProjectIDs projectIDs: [String], generation: Int) {
        guard let client, capabilities?.supportsWorktrees == true else { return }
        for projectID in projectIDs
        where worktreeSessions[projectID] == nil && !seededWorktreeCountProjectIDs.contains(projectID) {
            seededWorktreeCountProjectIDs.insert(projectID)
            Task { [weak self] in
                guard let response = try? await client.worktreesList(
                    SupermuxWorktreesListRequest(projectID: projectID)
                ) else { return }
                guard let self, self.generation == generation else { return }
                self.recordWorktrees(response.worktrees, forProjectID: projectID)
            }
        }
    }
}
