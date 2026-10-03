import CmuxSettingsUI
import Foundation

/// Serves the Settings "Remote Macs" card (`SupermuxRemoteMacsSettingsCard`,
/// which finds this conformance with a dynamic cast of its settings host), so
/// upstream's `SettingsHostActions` protocol needs no new requirement.
extension HostSettingsActions: SupermuxRemoteMacsSettingsHosting {
    func supermuxRemoteMacsSettingsActions() -> SupermuxRemoteMacsSettingsActions {
        SupermuxComposition.remoteMacsSettings.actions()
    }
}
