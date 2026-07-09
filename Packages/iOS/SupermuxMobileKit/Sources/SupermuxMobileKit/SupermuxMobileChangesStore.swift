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
    public private(set) var lastErrorDescription: String?

    /// Whether a stage/unstage/discard round-trip is on the wire (rows
    /// disable their actions while `true`; mutations are serialized).
    public private(set) var isMutating = false

    /// The workspace whose repository this store follows (UUID string).
    public let workspaceID: String

    @ObservationIgnored private let client: any SupermuxMacCalling
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
        // Unstructured so the cancelled task cannot cancel the RPC itself.
        let client = self.client
        let request = SupermuxChangesWatchRequest(workspaceID: workspaceID, enable: false)
        Task { _ = try? await client.changesWatch(request) }
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
                selection: .paths(paths)
            ))
        }
    }

    /// `mobile.supermux.changes.stage` with `all: true`.
    public func stageAll() async {
        await mutate {
            _ = try await self.client.changesStage(SupermuxChangesStageRequest(
                workspaceID: self.workspaceID,
                selection: .all
            ))
        }
    }

    /// `mobile.supermux.changes.unstage` for the given paths.
    /// - Parameter paths: Repo-root-relative paths to unstage.
    public func unstage(paths: [String]) async {
        await mutate {
            _ = try await self.client.changesUnstage(SupermuxChangesUnstageRequest(
                workspaceID: self.workspaceID,
                selection: .paths(paths)
            ))
        }
    }

    /// `mobile.supermux.changes.unstage` with `all: true`.
    public func unstageAll() async {
        await mutate {
            _ = try await self.client.changesUnstage(SupermuxChangesUnstageRequest(
                workspaceID: self.workspaceID,
                selection: .all
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
                paths: paths
            ))
        }
    }

    // MARK: - Internals

    /// One mutation at a time: send, then refetch so the sections move
    /// without waiting for the Mac's poke. Failures surface in
    /// ``lastErrorDescription`` — never a silent no-op.
    private func mutate(_ operation: @MainActor () async throws -> Void) async {
        guard !isMutating else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            try await operation()
            await refetchStatus()
        } catch {
            lastErrorDescription = error.localizedDescription
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
            _ = try? await client.changesWatch(
                SupermuxChangesWatchRequest(workspaceID: workspaceID, enable: true)
            )
            await heartbeatSleep(Self.heartbeatInterval)
        }
    }

    private func refetchStatus() async {
        do {
            status = try await client.changesStatus(
                SupermuxChangesStatusRequest(workspaceID: workspaceID)
            )
            hasLoaded = true
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }
}
