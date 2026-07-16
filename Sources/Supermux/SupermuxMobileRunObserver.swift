import Foundation
import SupermuxKit
import SupermuxMobileCore

/// Watches the ⌘G run coordinator's live-run projection and emits
/// `supermux.run.updated` to subscribed mobile clients on every transition —
/// start, stop, restart, whether it came from the phone's
/// `mobile.supermux.run.start`/`run.stop` handlers or the desktop toggle
/// (both mutate the same `SupermuxRunCoordinator` handles, so this is the
/// single emission path and double-pokes are impossible).
///
/// Same pattern as ``SupermuxMobileProjectsObserver``: re-arming
/// `withObservationTracking` around one summary-hash read, one trailing
/// 80 ms pass per mutation burst, emit a payload-light poke (the phone
/// refetches via `mobile.supermux.run.state`).
///
/// The snapshot reader is injected so tests drive transitions through a fake
/// `@Observable` source: the production reader
/// (`SupermuxComposition.runCoordinator.mobileRunSnapshots`) touches GUI
/// workspace state that cannot exist in a windowless test run. A run surface
/// closed WITHOUT a coordinator mutation (covered on the desktop by
/// `reconcile(workspace:)` from the presets bar) is observed at the next
/// handle mutation, mirroring the desktop bar's own staleness window.
@MainActor
final class SupermuxMobileRunObserver {
    private let readSnapshots: @MainActor () -> [SupermuxMobileRunSnapshot]
    private let emit: @MainActor (_ topic: String, _ payload: [String: Any]) -> Void
    private var lastSummaryHash: Int = 0
    /// The scheduled trailing pass; `nil` when idle. Its presence is the
    /// throttle: at most one emit-check per window.
    private var pendingPass: Task<Void, Never>?
    /// Throttle window, mirroring `MobileWorkspaceListObserver`.
    private let throttleMilliseconds: Int = 80

    /// Creates the observer and emits the initial snapshot unconditionally so
    /// freshly-paired clients see current state without waiting for a mutation.
    ///
    /// - Parameters:
    ///   - readSnapshots: Reads the live-run projection; the read is wrapped
    ///     in observation tracking, so it must touch the observable source.
    ///   - emit: The event sink; defaults to `MobileHostService.emitEvent`.
    init(
        readSnapshots: @escaping @MainActor () -> [SupermuxMobileRunSnapshot],
        emit: @escaping @MainActor (_ topic: String, _ payload: [String: Any]) -> Void = { topic, payload in
            MobileHostService.shared.emitEvent(topic: topic, payload: payload)
        }
    ) {
        self.readSnapshots = readSnapshots
        self.emit = emit
        emitIfNeededAndRearm(force: true)
    }

    deinit {
        pendingPass?.cancel()
    }

    /// Schedules the trailing emit pass unless one is already pending.
    private func runsDidChange() {
        guard pendingPass == nil else { return }
        pendingPass = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.throttleMilliseconds ?? 80) * 1_000_000))
            guard let self, !Task.isCancelled else { return }
            self.pendingPass = nil
            self.emitIfNeededAndRearm(force: false)
        }
    }

    /// Reads the summary hash (re-arming observation atomically with the
    /// read), emits when it changed, and stores the new value.
    private func emitIfNeededAndRearm(force: Bool) {
        let hash = withObservationTracking {
            Self.summaryHash(snapshots: readSnapshots())
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.runsDidChange()
            }
        }
        if !force, hash == lastSummaryHash {
            return
        }
        lastSummaryHash = hash
        emit(SupermuxMobileTopic.runUpdated.rawValue, [:])
    }

    /// Stable hash of the iOS-facing projection: every live run's identity,
    /// command, and start time (the exact fields `run.state` serves).
    private static func summaryHash(snapshots: [SupermuxMobileRunSnapshot]) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshots)
        return hasher.finalize()
    }
}
