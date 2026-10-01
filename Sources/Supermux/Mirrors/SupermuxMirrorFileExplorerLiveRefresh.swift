import Foundation
import SupermuxKit

/// Keeps a mirror's Files panel current the way the local panel's directory
/// watcher does: it leases the owning Mac's watcher for the workspace's folder
/// (`changes.watch`, the Changes panel's own lease, under its own client id)
/// and reloads the tree and git colors on each change, at most once a second.
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

    /// Starts (or restarts) the refresh for the store's device provider.
    static func start(for store: FileExplorerStore) {
        let key = ObjectIdentifier(store)
        running.removeValue(forKey: key)?.cancel()
        guard let provider = store.provider as? SupermuxDeviceFileExplorerProvider,
              let target = SupermuxComposition.mirrorResolver.target(forWorkspaceID: provider.root.workspaceID) else { return }
        let backend = SupermuxRemoteChangesBackend(
            transport: SupermuxDeviceChangesTransport(target: target, devices: SupermuxComposition.devices),
            clientID: "supermux-files-\(UUID().uuidString)"
        )
        let token = UUID()
        let signals = Task { @MainActor [weak store] in
            let clock = ContinuousClock()
            var lastRefresh = clock.now - Self.minimumInterval
            for await _ in backend.changeSignals(repoPath: provider.root.rootPath) {
                let wait = lastRefresh + Self.minimumInterval - clock.now
                if wait > .zero { try? await Task.sleep(for: wait) }
                guard let store, store.provider === provider, !Task.isCancelled else { return }
                lastRefresh = clock.now
                store.reload()
                store.refreshGitStatus()
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
