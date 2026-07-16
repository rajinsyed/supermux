public import Foundation
public import SupermuxMobileKit

/// The session-lifecycle half of ``SupermuxProjectsSectionModel`` (m6-f3):
/// how a connection's session starts, pauses across a navigation push/pop,
/// resumes, gets replaced by a new connection, and ends — split from the
/// main file to respect the per-file length budget.
extension SupermuxProjectsSectionModel {
    /// Runs one connection's session and follows the live event streams
    /// until the caller (the driver's `.task(id:)`) is cancelled. Against a
    /// host without `supermux.projects.v1` the store is inert (no RPC is
    /// ever issued) and the section stays hidden.
    ///
    /// Session lifecycle (m6-f3, stale-while-revalidate):
    /// - A NEW connection identity builds fresh stores and publishes them.
    /// - Cancellation merely PAUSES the session: the stores stay installed
    ///   (the section keeps rendering its loaded content while a navigation
    ///   push covers the list, and instantly on pop — it never regresses to
    ///   hidden or to a loading placeholder), and every event loop —
    ///   including the expanded projects' worktree loops — stops, so a
    ///   covered list never keeps polling (or re-dialling a dead
    ///   connection) in the background. Teardown happens only through
    ///   ``endSession()`` (disconnect) or a replacement run.
    /// - A re-run with the SAME `connectionID` (pop with the connection
    ///   unchanged) RESUMES the retained stores: no state resets, the
    ///   re-entered loops resubscribe and refetch, silently revalidating
    ///   the retained content.
    ///
    /// - Parameters:
    ///   - client: The Mac RPC seam for THIS connection. Ignored on resume
    ///     (the retained session's equivalent client keeps serving).
    ///   - hostCapabilities: The host's raw advertised capability strings.
    ///   - connectionID: The driver's task identity for this connection
    ///     (client identity + capability snapshot). `nil` always replaces.
    public func runSession(
        client: any SupermuxMacCalling,
        hostCapabilities: Set<String>,
        connectionID: AnyHashable? = nil
    ) async {
        loopEpoch += 1
        let epoch = loopEpoch
        let store: SupermuxMobileProjectsStore
        let runStore: SupermuxMobileRunStore
        if let connectionID, connectionID == sessionConnectionID,
           let retainedStore = self.store, let retainedRunStore = self.runStore {
            // RESUME: the pop re-runs the driver's task for the same
            // connection. Keep the stores (their loaded state renders
            // immediately), the worktree-session stores (their loaded
            // nested rows too), the counts, the collapse override, and the
            // session generation (the retained stores' callbacks captured
            // it — bumping here would kill pruning/seeding/count recording
            // for the rest of the session). Only the loops restart.
            store = retainedStore
            runStore = retainedRunStore
            resumeWorktreeSessionLoops()
        } else {
            collapsedOverride = nil
            // A replacement session must never inherit the old connection's
            // worktree sessions (stale client) — end them before installing
            // the new client, then reseed below. The generation bump
            // invalidates the old session's in-flight work (nested opens,
            // prune callbacks, count recording).
            endAllWorktreeSessions()
            sessionGeneration += 1
            let generation = sessionGeneration
            let capabilities = SupermuxMobileCapabilities(hostCapabilities: hostCapabilities)
            let freshStore = SupermuxMobileProjectsStore(
                client: client,
                capabilities: capabilities,
                iconCache: iconCache,
                // The authoritative list prunes worktree sessions whose
                // project was deleted (their rows are gone, so they could
                // never be collapsed away — without this they would refetch
                // forever). Generation-guarded: a lingering OLD store (kept
                // alive by an in-flight write's refetch across a reconnect)
                // must never prune the NEW session with the old Mac's
                // project ids.
                onProjectsChanged: { [weak self] projects in
                    guard let self, self.sessionGeneration == generation else { return }
                    self.pruneWorktreeSessions(keepingProjectIDs: projects.map(\.id))
                    // Mirror the mac's eager per-project worktree refresh at
                    // load: collapsed projects get a one-shot count fetch so
                    // the worktree capsule shows without expanding.
                    self.seedWorktreeCounts(
                        forProjectIDs: projects.map(\.id),
                        generation: generation
                    )
                }
            )
            let freshRunStore = SupermuxMobileRunStore(client: client, capabilities: capabilities)
            self.store = freshStore
            self.runStore = freshRunStore
            sessionClient = client
            sessionCapabilities = capabilities
            sessionConnectionID = connectionID
            worktreeCounts = [:]
            seededWorktreeCountProjectIDs = []
            // Resume the phone-persisted inline disclosures against THIS
            // connection: each expanded project fetches on session start and
            // refetches on `supermux.worktrees.updated` (the store's own
            // loop).
            for projectID in expandedProjectIDs {
                startWorktreeSession(forProjectID: projectID)
            }
            store = freshStore
            runStore = freshRunStore
        }
        defer {
            // NO teardown on exit (m6-f3). Cancellation here is a navigation
            // push covering the list (workspace row or project detail —
            // NavigationStack removes the root from the hierarchy, so
            // SwiftUI cancels the driver's structured `.task`) or the list
            // leaving the screen. Tearing down used to blank the section
            // (visible reload + scroll reset on pop) and, with a detail
            // pushed, swap it for the "no longer available" placeholder (the
            // m6-f1 field bug). The session stays installed — the connection
            // is still alive, so detail/run actions keep working — but ALL
            // its loops pause, including the worktree ones, until a resume,
            // a replacement run, ``endSession()``, or the owning view's
            // destruction (see `deinit`). Epoch-guarded: after a rapid pop
            // has already resumed the loops, this late exit must not pause
            // them again; the store-identity check keeps a replaced run from
            // touching the sessions its replacement now owns.
            if loopEpoch == epoch, self.store === store {
                pauseWorktreeSessionLoops()
            }
        }
        // Single-flight loop ownership: the projects/run loops run in an
        // unstructured task CHAINED behind the previous run's loops, so one
        // store never runs two subscriptions concurrently even when a rapid
        // pop re-enters runSession while the push-cancelled loops are still
        // unwinding. The cancellation handler ties the chained task back to
        // the driver's structured `.task` lifetime (push still pauses).
        let previousLoops = sessionLoops
        let loops = Task { [store, runStore] in
            await previousLoops?.value
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await store.run() }
                group.addTask { await runStore.run() }
            }
        }
        sessionLoops = loops
        await withTaskCancellationHandler {
            await loops.value
        } onCancel: {
            loops.cancel()
        }
    }

    /// Drops the session immediately (connection went away). Expansion
    /// state itself persists — a reconnect reseeds the worktree sessions.
    public func endSession() {
        store = nil
        runStore = nil
        sessionClient = nil
        sessionCapabilities = nil
        sessionConnectionID = nil
        worktreeCounts = [:]
        seededWorktreeCountProjectIDs = []
        collapsedOverride = nil
        endAllWorktreeSessions()
        sessionLoops?.cancel()
        sessionGeneration += 1
        // detailProjectID / detailFallbackRow survive on purpose: a pushed
        // detail outliving a disconnect keeps rendering its last-known row
        // instead of flashing "no longer available".
    }
}
