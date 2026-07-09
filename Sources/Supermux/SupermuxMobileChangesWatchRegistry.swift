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
    /// Lease duration: an entry not heartbeated for this long is swept.
    static let ttl: TimeInterval = 120
    /// How often the automatic sweep re-checks the leases.
    static let sweepInterval: Duration = .seconds(30)

    private struct Entry {
        var directory: String
        var lastHeartbeat: Date
        var watchTask: Task<Void, Never>
    }

    private let now: @MainActor () -> Date
    private let makeChangeStream: @MainActor (String) -> AsyncStream<Void>
    private let emit: @MainActor (_ topic: String, _ payload: [String: Any]) -> Void
    private let sweepsAutomatically: Bool
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
    init(
        now: @escaping @MainActor () -> Date = { Date() },
        makeChangeStream: @escaping @MainActor (String) -> AsyncStream<Void> = { path in
            SupermuxRepositoryWatcher(path: path).changes()
        },
        emit: @escaping @MainActor (_ topic: String, _ payload: [String: Any]) -> Void = { topic, payload in
            MobileHostService.shared.emitEvent(topic: topic, payload: payload)
        },
        sweepsAutomatically: Bool = true
    ) {
        self.now = now
        self.makeChangeStream = makeChangeStream
        self.emit = emit
        self.sweepsAutomatically = sweepsAutomatically
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

    /// Starts (or heartbeats) the watch lease for one workspace.
    ///
    /// A fresh call for an already-watched workspace on the same directory
    /// only renews the lease — the FSEvents stream keeps running. A changed
    /// directory (the workspace cd-ed elsewhere) tears the old watcher down
    /// and starts one on the new directory.
    /// - Parameters:
    ///   - workspaceId: The workspace to watch.
    ///   - directory: The workspace's current directory (tilde-expanded and
    ///     standardized here).
    func watch(workspaceId: String, directory: String) {
        let normalized = ((directory as NSString).expandingTildeInPath as NSString).standardizingPath
        if var entry = entries[workspaceId], entry.directory == normalized {
            entry.lastHeartbeat = now()
            entries[workspaceId] = entry
            return
        }
        entries[workspaceId]?.watchTask.cancel()
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
            lastHeartbeat: now(),
            watchTask: watchTask
        )
        startSweepingIfNeeded()
    }

    /// Releases one workspace's lease immediately (`enable: false`).
    /// Unknown ids are a no-op — releasing twice must not error.
    func unwatch(workspaceId: String) {
        entries.removeValue(forKey: workspaceId)?.watchTask.cancel()
        stopSweepingIfIdle()
    }

    /// Sweeps every lease whose last heartbeat is older than ``ttl``.
    func sweep() {
        let reference = now()
        for (workspaceId, entry) in entries
        where reference.timeIntervalSince(entry.lastHeartbeat) > Self.ttl {
            entry.watchTask.cancel()
            entries.removeValue(forKey: workspaceId)
        }
        stopSweepingIfIdle()
    }

    // MARK: - Internals

    /// Runs the periodic sweep while any lease exists (and automatic
    /// sweeping is enabled).
    private func startSweepingIfNeeded() {
        guard sweepsAutomatically, sweepTask == nil, !entries.isEmpty else { return }
        sweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SupermuxMobileChangesWatchRegistry.sweepInterval)
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
