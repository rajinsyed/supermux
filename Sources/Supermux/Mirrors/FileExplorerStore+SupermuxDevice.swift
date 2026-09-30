import Foundation

/// Applies a device mirror's Files root (`FileExplorerWorkspaceRoot.supermuxDevice`,
/// touchpoint `mirror-file-explorer-device`): the owning Mac's folder through
/// ``SupermuxDeviceFileExplorerProvider``, refreshed live from that Mac.
extension FileExplorerStore {
    func applySupermuxDeviceWorkspaceRoot(_ root: SupermuxMirrorFileRoot) {
        setWorkspaceRootIdentity(root.workspaceID)
        cancelRemoteHomeResolution()
        setRootStatusMessage(nil)
        if (provider as? SupermuxDeviceFileExplorerProvider)?.root != root {
            // A new folder (or Mac) is a new provider: nothing listed under
            // the old one may be read through the new one.
            setRootPath("")
            setProvider(SupermuxDeviceFileExplorerProvider(root: root, devices: SupermuxComposition.devices), reloadIfAvailable: false)
        }
        setRootPath(root.rootPath)
    }
}
