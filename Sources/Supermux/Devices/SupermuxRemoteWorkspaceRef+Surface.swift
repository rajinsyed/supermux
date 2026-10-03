import CMUXMobileCore
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

extension SupermuxRemoteWorkspaceRef {
    /// A ref from a catalog machine and a remote workspace id.
    init(machine: SurfaceMachineID, workspaceID: String) {
        self.init(machineID: machine.rawValue, workspaceID: workspaceID)
    }

    /// A ref to a device's synced workspace record.
    init(machine: SurfaceMachineID, record: WorkspaceSyncRecord) {
        self.init(machine: machine, workspaceID: record.id)
    }

    /// The catalog machine this ref names.
    var machine: SurfaceMachineID { SurfaceMachineID(rawValue: machineID) }
}
