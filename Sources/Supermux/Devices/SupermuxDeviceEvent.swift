import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// A per-device event delivered by ``SupermuxDevices/events()``.
enum SupermuxDeviceEvent: Sendable {
    /// The link (re)connected and its post-connect record fetch finished.
    /// Changes made on the other Mac while the link was down sent no event,
    /// so consumers refetch whatever they cache (projects, worktrees, run state).
    case linkConnected(SurfaceMachineID)
    /// The live link went away (transport lost, device offline, link stopped).
    case linkLost(SurfaceMachineID)
    /// The other Mac published a `supermux.*` poke; refetch through the
    /// matching RPC. `payload` is the raw event JSON (e.g. `{workspace_id}`
    /// for `supermux.changes.updated`), when the host sent one.
    case topic(SurfaceMachineID, SupermuxMobileTopic, payload: Data?)

    /// The device the event concerns.
    var machine: SurfaceMachineID {
        switch self {
        case .linkConnected(let machine), .linkLost(let machine), .topic(let machine, _, _):
            return machine
        }
    }

    /// The payload decoded as a JSON object, when there is one.
    var payloadObject: [String: Any]? {
        guard case .topic(_, _, let payload?) = self else { return nil }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }
}
