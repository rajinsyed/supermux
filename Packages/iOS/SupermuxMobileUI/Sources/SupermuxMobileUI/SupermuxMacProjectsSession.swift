import Foundation
import Observation
import SupermuxMobileCore
import SupermuxMobileKit

/// One connected Mac's Projects session: its projects and run stores, the
/// worktree sessions behind its expanded projects, and its worktree counts.
///
/// The section model owns one of these per Mac pairing, so a Mac's loaded
/// projects survive another Mac becoming the foreground, and nothing one Mac
/// answers can leak into another Mac's rows. Project ids here are the Mac's
/// own (plain) ids; the model maps them to per-Mac row keys.
///
/// Lifecycle (m6-f3, per Mac): a NEW connection identity installs fresh
/// stores; cancelling ``run(client:hostCapabilities:connectionID:)`` only
/// PAUSES the loops (a navigation push covers the list); re-running with the
/// SAME identity resumes the retained stores; ``end()`` tears down.
@MainActor
@Observable
final class SupermuxMacProjectsSession {
    /// One expanded project's worktree session: the store plus the task
    /// running its event loop. The task is `nil` while PAUSED; a resume
    /// chains the new loop behind the cancelled `predecessor`, so one store
    /// never runs two subscriptions concurrently.
    struct WorktreeSession {
        let store: SupermuxMobileWorktreesStore
        var task: Task<Void, Never>?
        var predecessor: Task<Void, Never>?
    }

    /// The pairing this session serves.
    let pairingID: String
    /// The Mac's identity and header facts, refreshed by the model.
    var mac: SupermuxMacInfo
    /// The live projects store; `nil` before the first run or after ``end()``.
    private(set) var store: SupermuxMobileProjectsStore?
    /// The live run store, alongside ``store``.
    private(set) var runStore: SupermuxMobileRunStore?
    /// Unopened-worktree counts per project id (the row capsule).
    var worktreeCounts: [String: Int] = [:]
    /// Observable stamp that moves whenever the connection behind the stores
    /// is replaced or ends, so a pushed detail screen rebinds.
    private(set) var epoch: Int

    /// Stamp captured by in-flight work; stale once the session is replaced
    /// or ended. Drawn from the shared counter, so never reused.
    @ObservationIgnored private(set) var generation: Int
    @ObservationIgnored private(set) var client: (any SupermuxMacCalling)?
    @ObservationIgnored private(set) var capabilities: SupermuxMobileCapabilities?
    @ObservationIgnored private var connectionID: AnyHashable?
    @ObservationIgnored private var loops: Task<Void, Never>?
    @ObservationIgnored private var loopEpoch = 0
    @ObservationIgnored var worktreeSessions: [String: WorktreeSession] = [:]
    @ObservationIgnored var seededWorktreeCountProjectIDs: Set<String> = []
    @ObservationIgnored let iconCache: SupermuxProjectIconCache
    @ObservationIgnored private let counter: SupermuxSessionCounter
    /// The plain project ids whose disclosure is open on this Mac, so a fresh
    /// install resumes their worktree sessions.
    @ObservationIgnored var expandedProjectIDs: @MainActor () -> Set<String> = { [] }
    /// Called when fresh stores replace the old connection's, so the model
    /// drops UI state raised against the old connection for this Mac.
    @ObservationIgnored var onReplaced: @MainActor () -> Void = {}

    /// Creates an idle session.
    /// - Parameters:
    ///   - mac: The Mac this session serves.
    ///   - iconCache: The icon cache shared by every session.
    ///   - counter: The model's stamp counter.
    init(mac: SupermuxMacInfo, iconCache: SupermuxProjectIconCache, counter: SupermuxSessionCounter) {
        self.pairingID = mac.pairingID
        self.mac = mac
        self.iconCache = iconCache
        self.counter = counter
        let stamp = counter.next()
        self.generation = stamp
        self.epoch = stamp
    }

    /// Runs this Mac's session until cancelled. Against a host without
    /// `supermux.projects.v1` the store is inert and issues no RPC.
    /// - Parameters:
    ///   - client: The Mac's RPC seam. Ignored on resume.
    ///   - hostCapabilities: The Mac's raw advertised capabilities.
    ///   - connectionID: The connection identity; `nil` always replaces.
    func run(
        client: any SupermuxMacCalling,
        hostCapabilities: Set<String>,
        connectionID: AnyHashable?
    ) async {
        loopEpoch += 1
        let runEpoch = loopEpoch
        let store: SupermuxMobileProjectsStore
        let runStore: SupermuxMobileRunStore
        if let connectionID, connectionID == self.connectionID,
           let retainedStore = self.store, let retainedRunStore = self.runStore {
            // RESUME: keep every store, count and generation; restart loops.
            store = retainedStore
            runStore = retainedRunStore
            resumeWorktreeSessionLoops()
        } else {
            (store, runStore) = install(client: client, hostCapabilities: hostCapabilities, connectionID: connectionID)
        }
        defer {
            // Cancellation PAUSES (m6-f3): the stores stay installed, every
            // loop stops. Epoch- and identity-guarded against a late exit.
            if loopEpoch == runEpoch, self.store === store {
                pauseWorktreeSessionLoops()
            }
        }
        let previousLoops = loops
        let newLoops = Task { [store, runStore] in
            await previousLoops?.value
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await store.run() }
                group.addTask { await runStore.run() }
            }
        }
        loops = newLoops
        await withTaskCancellationHandler {
            await newLoops.value
        } onCancel: {
            newLoops.cancel()
        }
    }

    /// Tears the session down (the Mac went away).
    func end() {
        store = nil
        runStore = nil
        client = nil
        capabilities = nil
        connectionID = nil
        worktreeCounts = [:]
        seededWorktreeCountProjectIDs = []
        endAllWorktreeSessions()
        loops?.cancel()
        bumpGeneration()
    }

    /// Installs fresh stores for a new connection identity.
    private func install(
        client: any SupermuxMacCalling,
        hostCapabilities: Set<String>,
        connectionID: AnyHashable?
    ) -> (SupermuxMobileProjectsStore, SupermuxMobileRunStore) {
        // The old connection's worktree sessions and in-flight work must not
        // survive into this one: end them and invalidate their stamp.
        endAllWorktreeSessions()
        bumpGeneration()
        onReplaced()
        let generation = self.generation
        let capabilities = SupermuxMobileCapabilities(hostCapabilities: hostCapabilities)
        let store = SupermuxMobileProjectsStore(
            client: client,
            capabilities: capabilities,
            iconCache: iconCache,
            onProjectsChanged: { [weak self] projects in
                // Generation-guarded: a lingering OLD store must never prune
                // or seed this session with the old connection's ids.
                guard let self, self.generation == generation else { return }
                self.pruneWorktreeSessions(keepingProjectIDs: projects.map(\.id))
                self.seedWorktreeCounts(forProjectIDs: projects.map(\.id), generation: generation)
            }
        )
        let runStore = SupermuxMobileRunStore(client: client, capabilities: capabilities)
        self.client = client
        self.capabilities = capabilities
        self.connectionID = connectionID
        worktreeCounts = [:]
        seededWorktreeCountProjectIDs = []
        self.store = store
        self.runStore = runStore
        for projectID in expandedProjectIDs() {
            startWorktreeSession(forProjectID: projectID)
        }
        return (store, runStore)
    }

    private func bumpGeneration() {
        let stamp = counter.next()
        generation = stamp
        epoch = stamp
    }

    /// Fetches a project's custom icon PNG through the etag cache and mirrors
    /// it for the notification service extension. `nil` when unknown, not
    /// custom, or superseded while in flight.
    /// - Parameter projectID: The project's Mac-local UUID string.
    func iconPNGData(forProjectID projectID: String) async -> Data? {
        guard let store, let project = store.projects.first(where: { $0.id == projectID }) else {
            return nil
        }
        let data = await store.iconPNGData(for: project)
        // Main-actor reentrancy point: revalidate before touching the shared
        // mirror, so a removed or replaced icon is never resurrected.
        guard !Task.isCancelled, self.store === store else { return nil }
        guard let currentProject = store.projects.first(where: { $0.id == projectID }),
              currentProject.hasCustomIcon == true else {
            SupermuxSharedProjectIconStore.removeIcon(forProjectID: projectID)
            return nil
        }
        guard currentProject.iconETag == project.iconETag else { return nil }
        // The extension has no RPC session and APNs caps payloads at 4 KB, so
        // this mirror is the only way a real logo reaches a push banner.
        if let data {
            SupermuxSharedProjectIconStore.store(data, forProjectID: projectID)
        }
        return data
    }

    deinit {
        // The loops deliberately outlive a cancelled driver task (m6-f3);
        // dropping a Task handle does not cancel it.
        loops?.cancel()
        for session in worktreeSessions.values {
            session.task?.cancel()
        }
    }
}
