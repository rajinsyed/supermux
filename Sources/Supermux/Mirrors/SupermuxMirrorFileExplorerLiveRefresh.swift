import Foundation
import SupermuxKit
import SupermuxMobileCore

/// Keeps a mirror's Files panel current the way the local panel's directory
/// watcher does: it leases the owning Mac's watcher on the folder's own
/// entries (``SupermuxMirrorFilesWatch``) and refreshes the tree in place on
/// each change, at most once a second, with the git colors after it. Edits
/// deeper in the tree do not refresh it, exactly as locally.
///
/// One refresh per store. It stops when the store shows another provider
/// (another folder, another workspace, the link dropped) or goes away; the
/// lease is released then (or lapses on the other Mac within its TTL).
@MainActor
enum SupermuxMirrorFileExplorerLiveRefresh {
    private struct Running {
        let token: UUID
        let signals: Task<Void, Never>
        let watchdog: Task<Void, Never>

        func cancel() {
            signals.cancel()
            watchdog.cancel()
        }
    }

    private static var running: [ObjectIdentifier: Running] = [:]
    private static let minimumInterval: Duration = .seconds(1)
    private static let checkInterval: Duration = .seconds(5)
    #if DEBUG
    /// How many refreshes each store's live refresh ran, changed or not (the
    /// DEBUG files driver's `counters`: a refresh that changes nothing is
    /// otherwise invisible).
    static var refreshRuns: [ObjectIdentifier: Int] = [:]
    #endif

    /// Starts (or restarts) the refresh for the store's device provider.
    static func start(for store: FileExplorerStore) {
        let key = ObjectIdentifier(store)
        running.removeValue(forKey: key)?.cancel()
        guard let provider = store.provider as? SupermuxDeviceFileExplorerProvider else { return }
        let watch = SupermuxMirrorFilesWatch(root: provider.root, devices: SupermuxComposition.devices)
        let token = UUID()
        let signals = Task { @MainActor [weak store] in
            let clock = ContinuousClock()
            var lastRefresh = clock.now - Self.minimumInterval
            for await _ in watch.signals() {
                let wait = lastRefresh + Self.minimumInterval - clock.now
                if wait > .zero { try? await Task.sleep(for: wait) }
                guard let store, store.provider === provider, !Task.isCancelled else { return }
                lastRefresh = clock.now
                #if DEBUG
                Self.refreshRuns[ObjectIdentifier(store), default: 0] += 1
                #endif
                await store.supermuxRefreshInPlace()
            }
        }
        let watchdog = Task { @MainActor [weak store] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checkInterval)
                guard let store, store.provider === provider else { break }
            }
            signals.cancel()
            if Self.running[key]?.token == token { Self.running[key] = nil }
        }
        running[key] = Running(token: token, signals: signals, watchdog: watchdog)
    }
}

/// A mirror Files panel's lease on the owning Mac's watcher for the folder it
/// shows (`mobile.supermux.files.watch`, its own client id): the folder's own
/// entries, never its subtree, like the local panel's watcher.
@MainActor
struct SupermuxMirrorFilesWatch {
    /// Renewal period, inside the host's 120 s lease TTL.
    static let renewal: Duration = .seconds(60)

    let root: SupermuxMirrorFileRoot
    let devices: SupermuxDevices
    let clientID = "supermux-files-\(UUID().uuidString)"

    /// Holds the lease while iterated (renewed, re-leased after a reconnect)
    /// and yields on each `supermux.files.updated` for this folder, and once
    /// after a reconnect (changes made while the link was down sent no
    /// event). Ending the iteration releases the lease.
    func signals() -> AsyncStream<Void> {
        let events = devices.events()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { @MainActor in
                await lease(true)
                let renewal = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: Self.renewal)
                        guard !Task.isCancelled else { return }
                        await lease(true)
                    }
                }
                for await event in events where event.machine == root.machine {
                    switch event {
                    case .linkConnected:
                        await lease(true)
                        continuation.yield()
                    case .topic(_, .filesUpdated, _):
                        if concerns(event.payloadObject) { continuation.yield() }
                    default:
                        continue
                    }
                }
                renewal.cancel()
                // The panel stopped iterating (this task is cancelled): release
                // from a fresh task so the request is not cancelled with it.
                Task { @MainActor in await lease(false) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Whether an event names this workspace and this folder (a panel that
    /// followed a `cd` ignores the old folder's last changes).
    private func concerns(_ payload: [String: Any]?) -> Bool {
        guard let workspaceID = payload?["workspace_id"] as? String,
              let folder = payload?["root"] as? String else { return false }
        return SupermuxRemoteWorkspaceRef.canonicalWorkspaceID(workspaceID)
            == SupermuxRemoteWorkspaceRef.canonicalWorkspaceID(root.remoteWorkspaceID)
            && Self.normalized(folder) == Self.normalized(root.rootPath)
    }

    /// Starts, renews or releases the lease; a refusal (an older Mac, a `cd`
    /// there answering `stale_root`, the link down) leaves refreshes to
    /// reconnects and re-roots.
    private func lease(_ enable: Bool) async {
        _ = try? await devices.request(
            SupermuxMobileMethod.filesWatch,
            params: [
                "enable": enable,
                "client_id": clientID,
                "workspace_id": root.remoteWorkspaceID,
                "expected_root": root.rootPath,
            ],
            on: root.machine
        )
    }

    private static func normalized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
