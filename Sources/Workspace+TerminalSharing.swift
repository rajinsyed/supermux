import AppKit
import Bonsplit
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation

/// Tab-bar side of shared terminal sizing: the avatar accessory on a
/// terminal's tab and the tab context-menu size actions. Every action goes
/// through ``TerminalSharingStore``, the same path as the size panel,
/// shortcut, command palette and socket.
@MainActor
extension Workspace {
    /// Shows or clears the presence accessory on the terminal's tab.
    func updateTerminalSharingPresence(panelId: UUID, snapshot: TerminalSharingSnapshot?) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        // SUPERMUX:begin tab-presence-accessory-hidden (upstream: `let presence = snapshot.flatMap { TerminalSharingDisplay(snapshot: $0).tabPresence() }`)
        let presence = supermuxTabPresence(snapshot.flatMap { TerminalSharingDisplay(snapshot: $0).tabPresence() })
        // SUPERMUX:end tab-presence-accessory-hidden
        bonsplitController.updateTab(tabId, presence: .some(presence))
    }

    // SUPERMUX:begin tab-presence-accessory-hidden
    /// What a terminal's tab shows of its sharing presence. The attached
    /// devices' avatar accessory is left off the tab (the size panel still
    /// lists them), while the presence itself stays, so the tab's context menu
    /// keeps its Size to My Window / Terminal Size / Disconnect Others section.
    /// The one place to add a tab-menu row for the attached Macs, should
    /// Bonsplit gain a host hook for one.
    private func supermuxTabPresence(_ presence: TabPresence?) -> TabPresence? {
        guard var presence else { return nil }
        presence.participants = []
        return presence
    }
    // SUPERMUX:end tab-presence-accessory-hidden

    /// Handles a size action from a terminal tab's context menu or accessory.
    ///
    /// - Returns: `false` for actions that are not size actions.
    @discardableResult
    func handleTerminalSharingContextAction(_ action: TabContextAction, for tab: Bonsplit.Tab) -> Bool {
        guard let panelId = panelIdFromSurfaceId(tab.id) else { return false }
        let controller = TerminalController.shared
        let store = controller.terminalSharing
        if let mode = action.sizeMode.flatMap({ TerminalSizingMode(rawValue: $0.rawValue) }) {
            // SUPERMUX:begin sizing-sticky-preference (a mode chosen here applies to every terminal on this Mac)
            if !SupermuxTerminalSizingDefaults.shared.userChoseMode(mode, surfaceID: panelId, store: store) { NSSound.beep() }
            // SUPERMUX:end sizing-sticky-preference
            if mode == .priority || mode == .fixed {
                // Priority order and the fixed grid are edited in the panel.
                controller.presentTerminalSizePanel(surfaceID: panelId, confirmDisconnectOthers: false)
            }
            return true
        }
        switch action {
        case .sizeToMyWindow:
            if !store.sizeToMe(surfaceID: panelId) { NSSound.beep() }
        case .toggleSizePanel:
            if !controller.presentTerminalSizePanel(surfaceID: panelId, confirmDisconnectOthers: false, toggle: true) {
                NSSound.beep()
            }
        case .disconnectOtherClients:
            if !controller.presentTerminalSizePanel(surfaceID: panelId, confirmDisconnectOthers: true) { NSSound.beep() }
        default:
            return false
        }
        return true
    }
}
