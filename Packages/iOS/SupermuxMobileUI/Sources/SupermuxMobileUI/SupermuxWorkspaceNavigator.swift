import Foundation

/// Resolves a Mac-local workspace id to the shell's row id for the owning Mac
/// (`store.workspaceID(matchingRemoteWorkspaceID:macDeviceID:instanceTag:)`),
/// or `nil` while that row is not listed yet.
public typealias SupermuxWorkspaceResolver = @MainActor (
    _ remoteWorkspaceID: String,
    _ macDeviceID: String?,
    _ instanceTag: String?
) -> String?

/// Turns "the Mac answered with workspace X" into a navigation.
///
/// Supermux RPCs answer with the Mac-local workspace id, while the shell's
/// rows are scoped per Mac once two Macs are paired. The navigator resolves
/// the id against the OWNING Mac; a freshly created workspace only appears
/// after that Mac's next list refresh, so an unresolved target parks until
/// ``retryPending()`` finds it — bounded by a timeout that reports the miss
/// instead of navigating late. A newer request always supersedes a parked one.
@MainActor
final class SupermuxWorkspaceNavigator {
    /// One requested navigation: a Mac-local id plus its owning pairing.
    struct Target: Hashable, Sendable {
        let remoteWorkspaceID: String
        let macDeviceID: String?
        let instanceTag: String?
    }

    /// The shell's resolver; `nil` (single legacy session) selects the
    /// Mac-local id as-is, which is the row id when rows are unscoped.
    var resolve: SupermuxWorkspaceResolver?
    /// Selects a row by its row id.
    var select: @MainActor (_ rowID: String) -> Void = { _ in }
    /// Reports a target whose row never appeared within the timeout.
    var onTimeout: @MainActor (_ target: Target) -> Void = { _ in }

    /// The parked target, if any.
    private(set) var pendingTarget: Target?

    private let timeout: Duration
    private var timeoutTask: Task<Void, Never>?

    /// Creates a navigator.
    /// - Parameter timeout: How long a target may stay parked.
    init(timeout: Duration) {
        self.timeout = timeout
    }

    /// Navigates to `target` now, or parks it until its row appears.
    func open(_ target: Target) {
        cancelPending()
        guard let resolve else {
            select(target.remoteWorkspaceID)
            return
        }
        if let rowID = resolve(target.remoteWorkspaceID, target.macDeviceID, target.instanceTag) {
            select(rowID)
            return
        }
        pendingTarget = target
        timeoutTask = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.pendingTarget == target else { return }
            self.cancelPending()
            self.onTimeout(target)
        }
    }

    /// Re-resolves the parked target (the shell's workspace list changed).
    func retryPending() {
        guard let target = pendingTarget, let resolve,
              let rowID = resolve(target.remoteWorkspaceID, target.macDeviceID, target.instanceTag) else {
            return
        }
        cancelPending()
        select(rowID)
    }

    /// The shell's selection moved to `rowID` through another path.
    /// - Parameter rowID: The newly selected row id, or `nil` when cleared.
    func shellSelectionDidChange(to rowID: String?) {}

    /// Drops the parked target without navigating or reporting.
    func cancelPending() {
        pendingTarget = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }
}
