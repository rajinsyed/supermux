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
///
/// The host also keeps one viewport per client id, so the pane that reported
/// its grid last speaks for this Mac on that terminal. Another live pane of
/// the same terminal only follows: its replays and re-reports leave the grid
/// out (``defers(_:surfaceID:pane:)``) until its own pane resizes or comes on
/// screen, instead of taking the size back, which made two panes of
/// different sizes resize the terminal in turn.
///
/// The host keeps one counts override per client id too, so whether it holds
/// this Mac's automatic `counts_override: false` (a speaking pane went off
/// screen) is kept here per client id and terminal
/// (``holdsHiddenCounts(_:surfaceID:)``), not per pane: whichever pane speaks
/// next lifts it when it is on screen.
@MainActor
final class SupermuxDeviceViewportGenerations {
    static let shared = SupermuxDeviceViewportGenerations()

    private var highest: [String: [UUID: UInt64]] = [:]
    /// The local pane (surface id) whose grid the host holds, per client id
    /// and remote terminal.
    private var reporters: [String: [UUID: UUID]] = [:]
    /// The remote terminals, per client id, where the host holds this Mac's
    /// automatic `counts_override: false`.
    private var hiddenCounts: [String: Set<UUID>] = [:]

    /// Raises `viewer` to the floor of its client id and `surfaceID`.
    func raise(_ viewer: inout RemoteMacTerminalViewer?, surfaceID: UUID) {
        guard let clientID = viewer?.clientID, let floor = highest[clientID]?[surfaceID] else { return }
        viewer?.advanceGeneration(atLeast: floor)
    }

    /// Raises `viewer` above every generation this link reported for
    /// `surfaceID` and records it, so the report it sends next is applied
    /// after all earlier ones (the host drops a lower generation), whatever
    /// order the separate sends arrive in.
    func bump(_ viewer: inout RemoteMacTerminalViewer?, surfaceID: UUID) {
        raise(&viewer, surfaceID: surfaceID)
        guard let current = viewer?.generation else { return }
        viewer?.advanceGeneration(atLeast: current + 1)
        record(viewer, surfaceID: surfaceID)
    }

    /// Records the generation `viewer` just reported; with `pane`, that local
    /// pane's grid is now the one the host holds.
    func record(_ viewer: RemoteMacTerminalViewer?, surfaceID: UUID, reportedBy pane: UUID? = nil) {
        guard let viewer else { return }
        note(viewer.generation, clientID: viewer.clientID, surfaceID: surfaceID)
        if let pane { reporters[viewer.clientID, default: [:]][surfaceID] = pane }
    }

    /// Records the generation of the clear `viewer.clearParams()` sends from
    /// `pane`, which then no longer speaks for this Mac.
    func recordClear(_ viewer: RemoteMacTerminalViewer, surfaceID: UUID, pane: UUID?) {
        note(viewer.generation + 1, clientID: viewer.clientID, surfaceID: surfaceID)
        if let pane, reporters[viewer.clientID]?[surfaceID] == pane {
            reporters[viewer.clientID]?[surfaceID] = nil
        }
    }

    /// Whether another local pane of the terminal reported its grid on this
    /// link after `pane` did, so `pane` follows it instead of reporting.
    func defers(_ viewer: RemoteMacTerminalViewer?, surfaceID: UUID, pane: UUID?) -> Bool {
        guard let viewer, let pane, let reporter = reporters[viewer.clientID]?[surfaceID] else { return false }
        return reporter != pane
    }

    /// The local pane whose grid the host holds for `clientID` on `surfaceID`
    /// (the DEBUG tab-close driver reports it).
    func reporter(clientID: String, surfaceID: UUID) -> UUID? {
        reporters[clientID]?[surfaceID]
    }

    /// The local pane whose grid the host holds for `viewer`'s link on `surfaceID`.
    func reporter(of viewer: RemoteMacTerminalViewer?, surfaceID: UUID) -> UUID? {
        viewer.flatMap { reporters[$0.clientID]?[surfaceID] }
    }

    /// Whether the host holds this Mac's automatic `counts_override: false`
    /// for `viewer`'s link on `surfaceID`.
    func holdsHiddenCounts(_ viewer: RemoteMacTerminalViewer?, surfaceID: UUID) -> Bool {
        guard let viewer else { return false }
        return hiddenCounts[viewer.clientID]?.contains(surfaceID) ?? false
    }

    /// Records whether the host now holds that automatic `counts_override: false`.
    func setHoldsHiddenCounts(_ holds: Bool, _ viewer: RemoteMacTerminalViewer?, surfaceID: UUID) {
        guard let viewer else { return }
        if holds {
            hiddenCounts[viewer.clientID, default: []].insert(surfaceID)
        } else {
            hiddenCounts[viewer.clientID]?.remove(surfaceID)
        }
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
