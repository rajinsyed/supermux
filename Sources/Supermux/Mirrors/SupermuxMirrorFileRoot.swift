import CmuxSurfaceCatalogModel
import Foundation

/// The Files root of a device mirror whose Mac serves
/// `supermux.files_read.v1`: the folder the owning Mac presents for the
/// workspace (its current directory, so the panel follows a `cd` there), read
/// over the device link. Equatable so the workspace observation re-applies
/// only when the folder, the Mac or its name actually changes.
struct SupermuxMirrorFileRoot: Equatable, Sendable {
    /// The local mirror workspace (the store's root identity).
    let workspaceID: UUID
    /// The owning Mac.
    let machine: SurfaceMachineID
    /// The owner's own spelling of its workspace id (every RPC's `workspace_id`).
    let remoteWorkspaceID: String
    /// The owning Mac's friendly name.
    let deviceName: String
    /// The folder on the owning Mac (also each RPC's `expected_root`).
    let rootPath: String
}
