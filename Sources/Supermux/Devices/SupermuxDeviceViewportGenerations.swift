import CmuxTerminalSharing
import Foundation

/// The highest viewport generation this Mac has sent another Mac, per link
/// client id and remote terminal (the `device-mirror-viewport-generations`
/// touchpoint).
///
/// The host fences viewport reports per client id: it rejects a generation
/// below the last one it saw, a clear's included, until the connection
/// closes. Every mirror pane on one link shares that client id, but each
/// ``RemoteMacTerminalViewer`` counted from 0, so a pane that re-projected a
/// terminal after a refused close, a tab reopened on the same link, or a
/// second pane on the same terminal reported below the fence. Its replay then
/// answered `viewport_transition` until the retries ran out and the pane
/// showed "Mac disconnected" for the rest of the link's life. Raising every
/// viewer to this floor before it reports keeps the generations of one
/// terminal increasing across its panes.
@MainActor
final class SupermuxDeviceViewportGenerations {
    static let shared = SupermuxDeviceViewportGenerations()

    private var highest: [String: [UUID: UInt64]] = [:]

    /// Raises `viewer` to the floor of its client id and `surfaceID`.
    func raise(_ viewer: inout RemoteMacTerminalViewer?, surfaceID: UUID) {
        guard let clientID = viewer?.clientID, let floor = highest[clientID]?[surfaceID] else { return }
        viewer?.advanceGeneration(atLeast: floor)
    }

    /// Records the generation `viewer` just reported.
    func record(_ viewer: RemoteMacTerminalViewer?, surfaceID: UUID) {
        guard let viewer else { return }
        note(viewer.generation, clientID: viewer.clientID, surfaceID: surfaceID)
    }

    /// Records the generation of the clear `viewer.clearParams()` sends.
    func recordClear(_ viewer: RemoteMacTerminalViewer, surfaceID: UUID) {
        note(viewer.generation + 1, clientID: viewer.clientID, surfaceID: surfaceID)
    }

    /// The wait before replaying again after the host's `attempt`-th
    /// `viewport_transition` (50, 100, then 200 ms), so a transient resize on
    /// the host cannot use up the retries within a millisecond.
    nonisolated static func transitionRetryDelayNanoseconds(attempt: Int) -> UInt64 {
        50_000_000 << UInt64(min(max(attempt - 1, 0), 2))
    }

    private func note(_ generation: UInt64, clientID: String, surfaceID: UUID) {
        highest[clientID, default: [:]][surfaceID] = max(highest[clientID]?[surfaceID] ?? 0, generation)
    }
}
