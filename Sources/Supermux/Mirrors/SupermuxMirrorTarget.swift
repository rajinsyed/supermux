import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// A local device mirror resolved to the remote workspace it shows: what
/// workspace-scoped fork features (⌘G, presets, Changes, Files) act on
/// instead of the mirror's own — local, meaningless — `currentDirectory`.
///
/// Every id here is the OWNER's: `remoteWorkspaceID` is the other Mac's
/// workspace id and `remoteProjectID` its project id. Never look them up as
/// local ids (with the loopback device they collide with local ids and seem
/// to work; between two real Macs they would not).
struct SupermuxMirrorTarget: Equatable, Sendable {
    /// The canonical remote workspace reference.
    let ref: SupermuxRemoteWorkspaceRef
    /// The local mirror workspace.
    let localWorkspaceID: UUID
    /// The owning Mac's friendly name ("On <Mac>").
    let deviceName: String
    /// Whether the link to that Mac is live.
    let isConnected: Bool
    /// The owner's own spelling of its workspace id (the synced record's id).
    let remoteWorkspaceID: String
    /// The remote workspace's presented directory on the owning Mac.
    let remoteDirectory: String?
    /// The owning Mac's project for the workspace (`supermux_project_id`).
    let remoteProjectID: String?

    /// The device machine.
    var machine: SurfaceMachineID { ref.machine }
}
