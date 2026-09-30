import Foundation
internal import SupermuxMobileCore

/// The Changes panel's engine for a device mirror: every status read and git
/// mutation runs on the Mac that owns the workspace, over
/// `mobile.supermux.changes.*` (the same host handlers the iPhone uses).
///
/// Calls are keyed by the OWNER's workspace id (``SupermuxRemoteChangesTransport/remoteWorkspaceID``)
/// and mutations carry `expected_root` — the root the last status reported —
/// so a remote `cd` can never make a stale panel stage or discard in another
/// repository (the host answers `stale_root`; the model's follow-up refresh
/// picks up the new root). Reply deadlines are the device facade's
/// per-method table (``SupermuxDeviceReplyDeadline``), never set here.
///
/// ```swift
/// let backend = SupermuxRemoteChangesBackend(transport: transport)
/// let model = SupermuxChangesModel(backend: backend,
///                                  commitGenerator: SupermuxRemoteCommitMessenger(backend: backend))
/// ```
@MainActor
public final class SupermuxRemoteChangesBackend: SupermuxChangesBackend {
    /// How long one history page answers the Unpushed/Incoming reads: a page
    /// is several git reads over there, so watcher-driven refreshes reuse it.
    static let historyLifetime: Duration = .seconds(15)
    /// The host's watch lease lasts 120 s; renew well inside it.
    static let leaseRenewal: Duration = .seconds(60)
    private static let historyPageSize = 200

    private struct HistoryPage {
        let unpushed: [SupermuxGitCommit]
        let incoming: [SupermuxGitCommit]
    }

    private let transport: any SupermuxRemoteChangesTransport
    private let clientID: String
    private let clock = ContinuousClock()
    /// The repository root the host reported last (the `expected_root` guard).
    private var lastRoot: String?
    private var lastSnapshot: SupermuxGitStatusSnapshot?
    private var history: (readAt: ContinuousClock.Instant, page: HistoryPage)?
    /// The host said it cannot write commit messages (no AI key there).
    public private(set) var isAIUnavailable = false

    /// Creates the backend.
    /// - Parameters:
    ///   - transport: The link to the owning Mac.
    ///   - clientID: This viewer's watch-lease holder id (unique per backend).
    public init(transport: any SupermuxRemoteChangesTransport, clientID: String? = nil) {
        self.transport = transport
        self.clientID = clientID ?? "supermux-mirror-\(UUID().uuidString)"
    }

    public nonisolated var isRemote: Bool { true }

    // MARK: - Status

    public func status(repoPath: String) async -> SupermuxGitStatusSnapshot {
        do {
            let result = try await call(.changesStatus)
            let dto = try SupermuxWireJSON().decode(SupermuxChangesStatusDTO.self, from: result)
            if let root = dto.root, !root.isEmpty { lastRoot = root }
            let snapshot = SupermuxGitStatusSnapshot(wire: dto)
            lastSnapshot = snapshot
            return snapshot
        } catch {
            // A dropped reply keeps the panel as it was instead of blanking it.
            return lastSnapshot ?? .notARepository
        }
    }

    // MARK: - Working tree

    public func stage(repoPath: String, paths: [String]) async throws {
        try await mutate(.changesStage, ["paths": paths], repoPath: repoPath)
    }

    public func stageAll(repoPath: String) async throws {
        try await mutate(.changesStage, ["all": true], repoPath: repoPath)
    }

    public func unstage(repoPath: String, paths: [String]) async throws {
        try await mutate(.changesUnstage, ["paths": paths], repoPath: repoPath)
    }

    public func unstageAll(repoPath: String) async throws {
        try await mutate(.changesUnstage, ["all": true], repoPath: repoPath)
    }

    public func discard(repoPath: String, change: SupermuxGitFileChange) async throws {
        try await mutate(.changesDiscard, ["paths": [change.path]], repoPath: repoPath)
    }

    /// The host discards only paths it re-validates as current changes, so
    /// "everything" is the fresh status's full list; a clean tree sends nothing.
    public func discardAll(repoPath: String) async throws {
        let snapshot = await status(repoPath: repoPath)
        let paths = (snapshot.staged + snapshot.unstaged + snapshot.untracked).map(\.path)
        guard !paths.isEmpty else { return }
        try await mutate(.changesDiscard, ["paths": Array(Set(paths)).sorted()], repoPath: repoPath)
    }

    public func commit(repoPath: String, message: String) async throws {
        try await mutate(.changesCommit, ["message": message], repoPath: repoPath)
    }

    public func push(repoPath: String, hasUpstream: Bool) async throws {
        try await mutate(.changesPush, [:], repoPath: repoPath)
    }

    public func pull(repoPath: String) async throws {
        try await mutate(.changesPull, [:], repoPath: repoPath)
    }

    public func stash(repoPath: String, includeUntracked: Bool) async throws {
        try await mutate(.changesStash, ["include_untracked": includeUntracked], repoPath: repoPath)
    }

    public func popStash(repoPath: String) async throws {
        try await mutate(.changesStashPop, [:], repoPath: repoPath)
    }

    // MARK: - History and fetch

    /// The host's first history page runs its own `git fetch` unless told
    /// not to, so a fetch is one fresh fetching page.
    public func fetch(repoPath: String) async -> Bool {
        history = nil
        return await historyPage(repoPath: repoPath, fetching: true) != nil
    }

    public func unpushedCountWithoutUpstream(repoPath: String) async -> Int {
        await historyPage(repoPath: repoPath)?.unpushed.count ?? 0
    }

    public func unpushedCommits(repoPath: String, hasUpstream: Bool, limit: Int) async -> [SupermuxGitCommit] {
        guard limit > 0 else { return [] }
        return Array((await historyPage(repoPath: repoPath)?.unpushed ?? []).prefix(limit))
    }

    public func incomingCommits(repoPath: String, limit: Int) async -> [SupermuxGitCommit] {
        guard limit > 0 else { return [] }
        return Array((await historyPage(repoPath: repoPath)?.incoming ?? []).prefix(limit))
    }

    /// One history page. Only ``fetch(repoPath:)`` lets the host fetch first:
    /// like the local engine, counts and feeds read what the last fetch left,
    /// so a refresh never waits on (or starts) network work over there.
    private func historyPage(repoPath: String, fetching: Bool = false) async -> HistoryPage? {
        if let history, clock.now - history.readAt < Self.historyLifetime { return history.page }
        do {
            var params: [String: Any] = ["limit": Self.historyPageSize]
            if !fetching { params["fetch"] = false }
            let result = try await call(.changesHistory, params, repoPath: repoPath)
            let wire = SupermuxWireJSON()
            let commits = try (result["commits"] as? [[String: Any]] ?? []).map { try wire.decode(SupermuxCommitDTO.self, from: $0) }
            let incoming = try (result["incoming"] as? [[String: Any]] ?? []).map { try wire.decode(SupermuxCommitDTO.self, from: $0) }
            let page = HistoryPage(
                unpushed: commits.filter { $0.isPushed == false }.map(SupermuxGitCommit.init(wire:)),
                incoming: incoming.map(SupermuxGitCommit.init(wire:))
            )
            history = (clock.now, page)
            return page
        } catch {
            return nil
        }
    }

    // MARK: - Diffs and AI capture

    public func fileDiff(repoPath: String, path: String, oldPath: String?, staged: Bool) async -> SupermuxGitFileDiff {
        do {
            let result = try await call(.changesDiff, ["path": path, "staged": staged], repoPath: repoPath)
            return SupermuxGitFileDiff(wire: try SupermuxWireJSON().decode(SupermuxDiffDTO.self, from: result))
        } catch {
            return .unavailable
        }
    }

    /// The remote stand-in for the AI flow's diff capture: the status
    /// fingerprint (the host generates the message from its own diff), so the
    /// staleness guard still notices files changing during generation.
    public func uncommittedDiff(repoPath: String) async -> String {
        await status(repoPath: repoPath).changeFingerprint
    }

    public func untrackedContentDigest(repoPath: String) async -> String { "" }

    public func trackedDiffDigest(repoPath: String) async -> String { "" }

    /// Asks the owning Mac to write a commit message for its uncommitted
    /// changes. `nil` on failure; an `ai_unavailable` answer also stops the
    /// panel offering Generate & Commit for this workspace.
    public func generateCommitMessage() async -> String? {
        do {
            let result = try await call(.changesGenerateCommitMessage, repoPath: "")
            let message = (result["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return message?.isEmpty == false ? message : nil
        } catch {
            if transport.errorCode(error) == "ai_unavailable" { isAIUnavailable = true }
            return nil
        }
    }

    // MARK: - Change signals

    /// Leases the host's repository watcher for as long as the stream is
    /// iterated (renewed inside the host's TTL, re-armed after a reconnect)
    /// and yields on each `supermux.changes.updated` for this workspace.
    public nonisolated func changeSignals(repoPath: String) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { @MainActor [weak self] in
                await self?.watch(yieldingTo: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func watch(yieldingTo continuation: AsyncStream<Void>.Continuation) async {
        let events = transport.events()
        await setWatchLease(true)
        let renewal = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.leaseRenewal)
                guard !Task.isCancelled else { return }
                await self?.setWatchLease(true)
            }
        }
        for await event in events {
            if event == .reconnected {
                history = nil
                await setWatchLease(true)
            }
            continuation.yield()
        }
        renewal.cancel()
        // The consumer is gone (this task is cancelled): release the lease
        // from a fresh task so the request is not cancelled with it. Switching
        // away from a mirror also drops this backend, so the task holds only
        // what the request needs, never `self`.
        let transport = self.transport
        let clientID = self.clientID
        Task { @MainActor in await Self.setWatchLease(false, clientID: clientID, on: transport) }
    }

    private func setWatchLease(_ enable: Bool) async {
        await Self.setWatchLease(enable, clientID: clientID, on: transport)
    }

    private static func setWatchLease(
        _ enable: Bool,
        clientID: String,
        on transport: any SupermuxRemoteChangesTransport
    ) async {
        _ = try? await transport.request(
            SupermuxMobileMethod.changesWatch.rawValue,
            params: ["enable": enable, "client_id": clientID, "workspace_id": transport.remoteWorkspaceID]
        )
    }

    // MARK: - Calls

    private func mutate(_ method: SupermuxMobileMethod, _ params: [String: Any], repoPath: String) async throws {
        history = nil
        _ = try await call(method, params, repoPath: repoPath)
    }

    /// One call keyed by the owner's workspace id; `repoPath` (when given)
    /// pins `expected_root` to the last reported root, else to the shown path.
    private func call(
        _ method: SupermuxMobileMethod,
        _ params: [String: Any] = [:],
        repoPath: String? = nil
    ) async throws -> [String: Any] {
        var params = params
        params["workspace_id"] = transport.remoteWorkspaceID
        if let repoPath, let root = lastRoot ?? (repoPath.isEmpty ? nil : repoPath) {
            params["expected_root"] = root
        }
        return try await transport.request(method.rawValue, params: params)
    }
}
