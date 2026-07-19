import Foundation
import SupermuxKit
import SupermuxMobileCore

/// Per-workspace repository watchers for the mobile Changes screen
/// (architecture §5): `mobile.supermux.changes.watch {enable: true}` starts a
/// ``SupermuxRepositoryWatcher`` on the workspace's directory and every
/// coalesced file-system change emits `supermux.changes.updated
/// {workspace_id}` so the phone refetches `changes.status`.
///
/// Watchers are leases, not subscriptions: the phone heartbeats every 60 s
/// (by re-sending `changes.watch {enable: true}`) while its Changes screen is
/// foregrounded, and an entry that misses heartbeats for ``ttl`` (120 s) is
/// swept — a phone that disconnects, backgrounds, or crashes can never leak
/// an FSEvents stream. `enable: false` releases the lease immediately.
///
/// The clock, the watch-stream factory, and the event sink are all
/// constructor-injected so the TTL contract (validation RPC-CHG-07) is
/// unit-testable without real FSEvents or a live mobile session.
@MainActor
final class SupermuxMobileChangesWatchRegistry {
    /// Lease duration: a holder not heartbeated for this long is swept.
    static let ttl: TimeInterval = 120
    /// How often the automatic sweep re-checks the leases.
    static let sweepInterval: Duration = .seconds(30)

    /// The holder token for a client that does not identify itself (an older
    /// phone build that omits `client_id`). All such clients collapse onto one
    /// token — the pre-multi-client behavior — so nothing regresses for them.
    static let legacyHolder = ""

    /// One workspace's watcher lease. `holders` maps each client token to its
    /// last heartbeat: a single FSEvents watcher is shared across every device
    /// viewing the workspace, and it is torn down only when the LAST holder
    /// releases or its lease expires — so one device closing its Changes sheet
    /// can never cancel a watcher another device is still heartbeating.
    private struct Entry {
        var directory: String
        var holders: [String: Date]
        var watchTask: Task<Void, Never>
    }

    private let now: @MainActor () -> Date
    private let makeChangeStream: @MainActor (String) -> AsyncStream<Void>
    private let emit: @MainActor (_ topic: String, _ payload: [String: Any]) -> Void
    private let sweepsAutomatically: Bool
    private let sweepIntervalValue: Duration
    private var entries: [String: Entry] = [:]
    private var sweepTask: Task<Void, Never>?

    /// Creates a registry.
    /// - Parameters:
    ///   - now: Clock; defaults to the wall clock. Injected for TTL tests.
    ///   - makeChangeStream: Watch-stream factory; defaults to a real
    ///     ``SupermuxRepositoryWatcher`` on the given directory.
    ///   - emit: The event sink; defaults to `MobileHostService.emitEvent`.
    ///   - sweepsAutomatically: Whether to run the periodic TTL sweep task;
    ///     tests pass `false` and call ``sweep()`` with an advanced clock.
    ///   - sweepInterval: How often the automatic sweep re-checks; defaults to
    ///     ``sweepInterval``. Tests injecting `sweepsAutomatically: true` pass a
    ///     tiny interval to exercise the real periodic sweep without a 30 s wait.
    init(
        now: @escaping @MainActor () -> Date = { Date() },
        makeChangeStream: @escaping @MainActor (String) -> AsyncStream<Void> = { path in
            SupermuxRepositoryWatcher(path: path).changes()
        },
        emit: @escaping @MainActor (_ topic: String, _ payload: [String: Any]) -> Void = { topic, payload in
            MobileHostService.shared.emitEvent(topic: topic, payload: payload)
        },
        sweepsAutomatically: Bool = true,
        sweepInterval: Duration? = nil
    ) {
        self.now = now
        self.makeChangeStream = makeChangeStream
        self.emit = emit
        self.sweepsAutomatically = sweepsAutomatically
        // Resolved here rather than as a default argument: default-argument
        // expressions evaluate in the caller's context, where touching the
        // @MainActor static warns under strict concurrency.
        self.sweepIntervalValue = sweepInterval ?? Self.sweepInterval
    }

    deinit {
        // Task.cancel() is thread-safe from a nonisolated deinit (same
        // pattern as the observers' pendingPass). The production registry is
        // a process-lifetime static, so this is belt-and-braces for tests.
        sweepTask?.cancel()
        for entry in entries.values {
            entry.watchTask.cancel()
        }
    }

    /// The workspace ids currently holding a watch lease (test seam).
    var watchedWorkspaceIds: [String] { Array(entries.keys) }

    /// Starts (or heartbeats) one client's watch lease for a workspace.
    ///
    /// A fresh call for an already-watched workspace on the same directory
    /// only renews the calling client's lease — the shared FSEvents stream
    /// keeps running. A changed directory (the workspace cd-ed elsewhere)
    /// tears the old watcher down and starts one on the new directory while
    /// preserving every client's holder lease.
    /// - Parameters:
    ///   - workspaceId: The workspace to watch.
    ///   - directory: The workspace's current directory (tilde-expanded and
    ///     standardized here).
    ///   - holder: The requesting client's stable token (`client_id`). Nil
    ///     from clients that do not identify themselves — see ``legacyHolder``.
    func watch(workspaceId: String, directory: String, holder: String? = nil) {
        let normalized = ((directory as NSString).expandingTildeInPath as NSString).standardizingPath
        let token = holder ?? Self.legacyHolder
        if var entry = entries[workspaceId], entry.directory == normalized {
            entry.holders[token] = now()
            entries[workspaceId] = entry
            return
        }
        // New workspace, or the workspace cd-ed elsewhere: (re)start the
        // watcher on the new directory, carrying over any OTHER clients'
        // holder leases so their view keeps updating on the new directory.
        var holders = entries[workspaceId]?.holders ?? [:]
        entries[workspaceId]?.watchTask.cancel()
        holders[token] = now()
        let stream = makeChangeStream(normalized)
        let emit = emit
        let watchTask = Task { @MainActor in
            for await _ in stream {
                if Task.isCancelled { return }
                emit(
                    SupermuxMobileTopic.changesUpdated.rawValue,
                    ["workspace_id": workspaceId]
                )
            }
        }
        entries[workspaceId] = Entry(
            directory: normalized,
            holders: holders,
            watchTask: watchTask
        )
        startSweepingIfNeeded()
    }

    /// Releases one client's lease (`enable: false`). The shared watcher is
    /// torn down only when the LAST holder releases. Unknown ids/holders are a
    /// no-op — releasing twice must not error.
    func unwatch(workspaceId: String, holder: String? = nil) {
        let token = holder ?? Self.legacyHolder
        guard var entry = entries[workspaceId] else { return }
        entry.holders.removeValue(forKey: token)
        if entry.holders.isEmpty {
            entry.watchTask.cancel()
            entries.removeValue(forKey: workspaceId)
        } else {
            entries[workspaceId] = entry
        }
        stopSweepingIfIdle()
    }

    /// Sweeps every holder whose last heartbeat is older than ``ttl``, tearing
    /// down a workspace's watcher once its last holder has expired.
    func sweep() {
        let reference = now()
        for workspaceId in Array(entries.keys) {
            guard var entry = entries[workspaceId] else { continue }
            for (token, beat) in Array(entry.holders)
            where reference.timeIntervalSince(beat) > Self.ttl {
                entry.holders.removeValue(forKey: token)
            }
            if entry.holders.isEmpty {
                entry.watchTask.cancel()
                entries.removeValue(forKey: workspaceId)
            } else {
                entries[workspaceId] = entry
            }
        }
        stopSweepingIfIdle()
    }

    // MARK: - Internals

    /// Runs the periodic sweep while any lease exists (and automatic
    /// sweeping is enabled).
    private func startSweepingIfNeeded() {
        guard sweepsAutomatically, sweepTask == nil, !entries.isEmpty else { return }
        sweepTask = Task { @MainActor [weak self, sweepIntervalValue] in
            while !Task.isCancelled {
                try? await Task.sleep(for: sweepIntervalValue)
                guard let self, !Task.isCancelled else { return }
                self.sweep()
            }
        }
    }

    /// Stops the periodic sweep once no lease remains.
    private func stopSweepingIfIdle() {
        guard entries.isEmpty else { return }
        sweepTask?.cancel()
        sweepTask = nil
    }
}
