import CmuxSurfaceCatalogModel
import Foundation

/// Mirror-tab closes made while the owning Mac was unreachable (the
/// `device-terminal-close-deferred` touchpoint).
///
/// Closing a mirror tab always removes it at once. When the link is down, or
/// drops while the close is on its way, the close is held here instead of
/// failing with a Cloud failure card; ``DeviceWorkspaceLayoutCoordinator``
/// sends every held close first when that Mac's link is back, under the same
/// rules as a live close (an idle terminal closes, a busy one asks, Cancel
/// brings the tab back, a terminal that no longer exists is dropped). Until
/// then the layout reconcile leaves a held terminal out
/// (``SupermuxDeviceLayoutSurfaceFilter``), so the tab never comes back on its
/// own. Held closes live in memory for the app's lifetime.
@MainActor
final class SupermuxDeviceHeldCloses {
    static let shared = SupermuxDeviceHeldCloses()

    struct Close: Equatable, Sendable {
        let remoteWorkspaceID: String
        let surfaceID: String
        /// The local mirror workspace the tab was closed in.
        let localWorkspaceID: UUID
    }

    private var held: [SurfaceMachineID: [Close]] = [:]

    /// Holds `close` for `machine`'s reconnect (once per terminal).
    func hold(_ close: Close, on machine: SurfaceMachineID) {
        guard !contains(surfaceID: close.surfaceID, remoteWorkspaceID: close.remoteWorkspaceID, on: machine) else { return }
        held[machine, default: []].append(close)
    }

    /// Removes and returns every close held for `machine`, oldest first.
    func take(on machine: SurfaceMachineID) -> [Close] {
        held.removeValue(forKey: machine) ?? []
    }

    /// The terminals of one remote workspace with a held close, canonicalized
    /// like ``canonical(_:)``.
    func surfaceIDs(remoteWorkspaceID: String, on machine: SurfaceMachineID) -> Set<String> {
        let workspace = Self.canonical(remoteWorkspaceID)
        return Set((held[machine] ?? []).filter { Self.canonical($0.remoteWorkspaceID) == workspace }.map { Self.canonical($0.surfaceID) })
    }

    /// Whether a held close failed only because its terminal or workspace no
    /// longer exists on that Mac, which needs no card.
    nonisolated static func isGone(_ error: any Error) -> Bool {
        guard let linkError = error as? DeviceLinkError, case let .hostRejected(code, _) = linkError else { return false }
        return code == "not_found"
    }

    /// The form ids are compared in: an uppercase UUID string, or the id itself.
    nonisolated static func canonical(_ id: String) -> String {
        UUID(uuidString: id)?.uuidString ?? id
    }

    private func contains(surfaceID: String, remoteWorkspaceID: String, on machine: SurfaceMachineID) -> Bool {
        surfaceIDs(remoteWorkspaceID: remoteWorkspaceID, on: machine).contains(Self.canonical(surfaceID))
    }
}
