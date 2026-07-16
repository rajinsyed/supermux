public import Foundation
import Observation
public import SupermuxMobileCore

/// Main-actor state for one workspace's git changes on the phone: the status
/// snapshot, event-driven refetches, the watch heartbeat, per-file diff
/// fetches, and the stage/unstage/discard actions.
///
/// Depends only on the ``SupermuxMacCalling`` seam and a fixed
/// ``SupermuxMobileCapabilities`` snapshot, both constructor-injected. Every
/// entry point is hidden (and the store inert) unless the host advertises
/// `supermux.changes.v1`.
///
/// Lifecycle: the changes screen runs ``run()`` inside a `.task` keyed on the
/// scene phase, so the live subscription AND the watch heartbeat are
/// structured — cancelled automatically when the screen disappears or the app
/// backgrounds, at which point one final `changes.watch {enable:false}` goes
/// out (the Mac's 120 s lease TTL is the backstop if that frame is lost).
@MainActor
@Observable
public final class SupermuxMobileChangesStore {
    /// How often the phone renews the Mac's watch lease while foregrounded.
    /// Half the Mac's 120 s TTL, so one lost heartbeat never drops the lease.
    public static let heartbeatInterval: Duration = .seconds(60)

    /// The latest status snapshot, or `nil` before the first success.
    public private(set) var status: SupermuxChangesStatusDTO?

    /// Whether at least one fetch has succeeded (drives placeholder vs list).
    public private(set) var hasLoaded = false

    /// Whether the live event stream is currently up.
    public private(set) var isConnected = false

    /// Human-readable description of the most recent fetch/mutation failure,
    /// for a non-blocking error surface. Cleared on the next success.
    public internal(set) var lastErrorDescription: String?

    /// Whether a stage/unstage/discard/commit/sync round-trip is on the wire
    /// (rows disable their actions while `true`; mutations are serialized).
    public internal(set) var isMutating = false

    // MARK: Commit / sync / history state (actions in …Store+Sync.swift)

    /// The commit-composer draft. Screen-bindable; cleared on a successful
    /// commit and populated by `generateAndCommit()`.
    public var commitMessage = ""

    /// The last successful commit's abbreviated sha, for a brief inline
    /// confirmation. Reset when the next commit starts.
    public internal(set) var lastCommitShortSha: String?

    /// The Mac's `ai_unavailable` message (no key configured, or generation
    /// failed — distinct messages). The screen wraps it in a friendly
    /// localized headline. Cleared when the next generation attempt starts.
    public internal(set) var aiUnavailableNotice: String?

    /// Whether a `generate_commit_message` round-trip is on the wire.
    public internal(set) var isGeneratingMessage = false

    /// The network-bound sync operation currently on the wire (drives the
    /// push/pull button spinners), or `nil` when idle.
    public internal(set) var activeSyncOperation: SupermuxChangesSyncOperation?

    /// The loaded local history pages, newest first.
    public internal(set) var historyCommits: [SupermuxCommitDTO] = []

    /// Upstream commits not yet pulled (first history page only).
    public internal(set) var incomingCommits: [SupermuxCommitDTO] = []

    /// Pass-back cursor for the next history page; `nil` = no more pages.
    public internal(set) var historyNextCursor: String?

    /// Whether a history page fetch is on the wire.
    public internal(set) var isLoadingHistory = false

    /// Whether the current history pages are fresh (false before the first
    /// load and after ``invalidateHistory()``).
    public internal(set) var hasLoadedHistory = false

    /// Human-readable description of the most recent history-fetch failure.
    /// Cleared on the next successful page.
    public internal(set) var historyErrorDescription: String?

    /// Bumped by ``invalidateHistory()``; the screen keys its history
    /// `.task(id:)` on it so a visible History segment reloads itself.
    public internal(set) var historyEpoch = 0

    /// The workspace whose repository this store follows (UUID string).
    public let workspaceID: String

    /// This store's stable watch-session id, sent as `client_id` on every
    /// `changes.watch` (enable AND disable) so the Mac can refcount watchers
    /// per client — one device closing its Changes sheet must not kill
    /// another device's live watcher.
    @ObservationIgnored private let watchClientID = UUID().uuidString

    /// The workspace's live repository root as last reported by a
    /// `changes.status` response, echoed back as `expected_root` on every
    /// mutation so the Mac can reject a stale view's mutation
    /// (`stale_root`). `nil` before the first status (or against an old Mac
    /// that omits `root`) — then no pin is sent. Internal so the sync
    /// extension's commit reaches it.
    @ObservationIgnored var currentRoot: String?

    /// The Mac RPC seam. Internal so the sync extension file reaches it.
    @ObservationIgnored let client: any SupermuxMacCalling
    @ObservationIgnored private let capabilities: SupermuxMobileCapabilities
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Cancellable reconnect-backoff sleep; injectable for deterministic tests.
    @ObservationIgnored private let idleSleep: (Duration) async -> Void
    /// The heartbeat's clock seam: sleeps one ``heartbeatInterval`` between
    /// beats in production; tests inject a gate and advance it explicitly.
    @ObservationIgnored private let heartbeatSleep: (Duration) async -> Void

    /// Whether the phone shows changes UI at all: gated on the host
    /// advertising `supermux.changes.v1`.
    public var showsChanges: Bool { capabilities.supportsChanges }

    /// Creates a changes store for one workspace.
    ///
    /// - Parameters:
    ///   - client: The Mac RPC seam.
    ///   - capabilities: The connected host's capability snapshot.
    ///   - workspaceID: The workspace's UUID string.
    ///   - now: Clock seam for the reconnect-health check.
    ///   - idleSleep: Backoff sleep seam; defaults to `Task.sleep`.
    ///   - heartbeatSleep: Heartbeat interval seam; defaults to `Task.sleep`.
    public init(
        client: any SupermuxMacCalling,
        capabilities: SupermuxMobileCapabilities,
        workspaceID: String,
        now: @escaping @Sendable () -> Date = { Date() },
        idleSleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        heartbeatSleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.capabilities = capabilities
        self.workspaceID = workspaceID
        self.now = now
        self.idleSleep = idleSleep
        self.heartbeatSleep = heartbeatSleep
    }

    /// Follows the live `supermux.changes.updated` stream AND renews the
    /// Mac's watch lease every ``heartbeatInterval`` until cancelled, then
    /// sends one `changes.watch {enable:false}`. A no-op without
    /// `supermux.changes.v1` — against an upstream Mac the store never issues
    /// a request. Event/backoff structure mirrors
    /// ``SupermuxMobileWorktreesStore/run()``.
    public func run() async {
        guard capabilities.supportsChanges else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.followEvents() }
            group.addTask { await self.heartbeat() }
        }
        // Reached on cancellation (screen disappeared / app backgrounded):
        // release the Mac-side watch promptly instead of riding out the TTL.
        // Routed through ``sendWatch(enable:)`` so a fresh session's enable
        // (push→pop→push can start `run()` again immediately) can never be
        // overtaken by this disable.
        sendWatch(enable: false)
    }

    /// `mobile.supermux.changes.diff`: one file's diff. Throws for the screen
    /// to render its retry state.
    ///
    /// - Parameters:
    ///   - path: Repo-root-relative file path (from the status snapshot).
    ///   - staged: Whether to diff the staged (index) side.
    /// - Returns: The diff payload (text, binary marker, truncation flag).
    public func loadDiff(path: String, staged: Bool) async throws -> SupermuxDiffDTO {
        try await client.changesDiff(
            SupermuxChangesDiffRequest(workspaceID: workspaceID, path: path, staged: staged)
        )
    }

    /// `mobile.supermux.changes.stage` for the given paths.
    /// - Parameter paths: Repo-root-relative paths to stage.
    public func stage(paths: [String]) async {
        await mutate {
            _ = try await self.client.changesStage(SupermuxChangesStageRequest(
                workspaceID: self.workspaceID,
                selection: .paths(paths),
                expectedRoot: self.currentRoot
            ))
        }
    }

    /// `mobile.supermux.changes.stage` with `all: true`.
    public func stageAll() async {
        await mutate {
            _ = try await self.client.changesStage(SupermuxChangesStageRequest(
                workspaceID: self.workspaceID,
                selection: .all,
                expectedRoot: self.currentRoot
            ))
        }
    }

    /// `mobile.supermux.changes.unstage` for the given paths.
    /// - Parameter paths: Repo-root-relative paths to unstage.
    public func unstage(paths: [String]) async {
        await mutate {
            _ = try await self.client.changesUnstage(SupermuxChangesUnstageRequest(
                workspaceID: self.workspaceID,
                selection: .paths(paths),
                expectedRoot: self.currentRoot
            ))
        }
    }

    /// `mobile.supermux.changes.unstage` with `all: true`.
    public func unstageAll() async {
        await mutate {
            _ = try await self.client.changesUnstage(SupermuxChangesUnstageRequest(
                workspaceID: self.workspaceID,
                selection: .all,
                expectedRoot: self.currentRoot
            ))
        }
    }

    /// `mobile.supermux.changes.discard` for the given paths. Destructive —
    /// callers confirm first (tracked files restore to HEAD; untracked files
    /// are deleted on the Mac). The Mac re-validates every path regardless.
    /// - Parameter paths: Repo-root-relative paths to discard.
    public func discard(paths: [String]) async {
        await mutate {
            _ = try await self.client.changesDiscard(SupermuxChangesDiscardRequest(
                workspaceID: self.workspaceID,
                paths: paths,
                expectedRoot: self.currentRoot
            ))
        }
    }

    // MARK: - Internals

    /// One mutation at a time: send, then refetch so the sections move
    /// without waiting for the Mac's poke. Failures surface in
    /// ``lastErrorDescription`` — never a silent no-op. Internal so the
    /// commit/sync actions in `…Store+Sync.swift` share the same gate.
    func mutate(_ operation: @MainActor () async throws -> Void) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await operation()
            await refetchStatus()
        } catch {
            if SupermuxWireErrorCode.code(from: error) == SupermuxWireErrorCode.staleRoot {
                // The Mac rejected the mutation because the phone's view was
                // composed against a repo root that has since changed. The
                // view is stale by definition — refetch FIRST (also
                // re-capturing the fresh root for the retry), THEN surface
                // the message, so the refetch's success can't clear it.
                await refetchStatus()
            }
            lastErrorDescription = error.localizedDescription
        }
    }

    /// Waits until no mutation is on the wire. Used by
    /// ``generateAndCommit(stageAll:)`` so its final `commit()` never hits
    /// the mutation gate and silently no-ops against a stage/unstage/discard
    /// that landed while generation was in flight — the store's "never a
    /// silent no-op" contract. A no-op when nothing is mutating.
    func waitForMutationSlot() async {
        while isMutating {
            await Task.yield()
        }
    }

    private func followEvents() async {
        var backoff: Duration = .zero
        while !Task.isCancelled {
            // Subscribe FIRST: pokes emitted while the fetch is in flight
            // buffer in the stream and replay after it, instead of dropping.
            let stream = await client.events(topics: [.changesUpdated])
            isConnected = true
            let streamStartedAt = now()
            await refetchStatus()
            for await event in stream where event.topic == .changesUpdated {
                // The poke carries the changed workspace; a missing payload
                // is treated as "might be us" (the poke itself is the signal).
                guard event.workspaceID == nil || event.workspaceID == workspaceID else { continue }
                await refetchStatus()
            }
            isConnected = false
            guard !Task.isCancelled else { return }
            // Liveness, not traffic, is the health signal — an idle stream can
            // legitimately stay silent for hours.
            let streamWasHealthy = now().timeIntervalSince(streamStartedAt) > 5
            if streamWasHealthy {
                backoff = .zero
            } else {
                backoff = min(max(backoff * 2, .milliseconds(500)), .seconds(16))
                await idleSleep(backoff)
            }
        }
    }

    /// Beat now, then every ``heartbeatInterval``: a failed beat is
    /// non-fatal (the next one retries; the Mac's TTL is the backstop).
    private func heartbeat() async {
        while !Task.isCancelled {
            sendWatch(enable: true)
            await heartbeatSleep(Self.heartbeatInterval)
        }
    }

    /// Serializes every `changes.watch` send — heartbeat enables AND the
    /// teardown disable in ``run()`` — into one FIFO chain keyed on this
    /// store instance: each call enqueues its send behind the chain's
    /// current tail (awaiting it first) and becomes the new tail. Without
    /// this, a torn-down session's trailing `enable:false` was an
    /// unstructured, unordered `Task` that could complete AFTER a freshly
    /// started session's `enable:true` (push→pop→push), killing the fresh
    /// watch lease. Fire-and-forget by design (mirrors the previous
    /// `run()` teardown call) so a cancelled `heartbeat()`/`run()` can never
    /// cancel the RPC itself — only the ORDER is guaranteed, not that every
    /// caller awaits completion.
    @ObservationIgnored private var watchSendChain: Task<Void, Never>?

    private func sendWatch(enable: Bool) {
        let client = self.client
        let workspaceID = self.workspaceID
        let clientID = self.watchClientID
        let previous = watchSendChain
        watchSendChain = Task {
            await previous?.value
            let request = SupermuxChangesWatchRequest(
                workspaceID: workspaceID,
                enable: enable,
                clientID: clientID
            )
            _ = try? await client.changesWatch(request)
        }
    }

    /// Monotonic request counter for ``refetchStatus()``: each call claims
    /// the next value, and only the latest may commit its result — so a
    /// slower, earlier-issued status fetch (e.g. one triggered by
    /// `followEvents()`'s poke handling racing a `mutate()` refetch from a
    /// concurrent stage/unstage/commit) can never overwrite a fresher
    /// response that already landed.
    @ObservationIgnored private var statusRequestGeneration = 0

    /// Internal so the sync extension refetches after commit/push/pull.
    func refetchStatus() async {
        statusRequestGeneration += 1
        let generation = statusRequestGeneration
        do {
            let response = try await client.changesStatus(
                SupermuxChangesStatusRequest(workspaceID: workspaceID)
            )
            guard generation == statusRequestGeneration else { return }
            status = response
            currentRoot = response.root
            hasLoaded = true
            lastErrorDescription = nil
        } catch {
            guard generation == statusRequestGeneration else { return }
            lastErrorDescription = error.localizedDescription
        }
    }

    /// Re-attempts the initial status fetch after it failed without ever
    /// succeeding (``hasLoaded`` still `false`) — the screen's Retry action
    /// when the first `changes.status` errors out. Safe to call while
    /// ``run()``'s own event loop is already live (idle between events):
    /// the request-generation guard on ``refetchStatus()`` keeps the two
    /// paths from racing.
    public func retryInitialLoad() async {
        await refetchStatus()
    }
}
