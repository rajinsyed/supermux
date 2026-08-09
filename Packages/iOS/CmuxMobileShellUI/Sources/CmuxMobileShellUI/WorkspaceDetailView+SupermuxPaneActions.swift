import CMUXMobileCore
import CmuxMobileToast
import SupermuxMobileUI
import SwiftUI

// SUPERMUX:begin ios-pane-actions
extension WorkspaceDetailView {
    var paneCloseConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { pendingPaneCloseTarget != nil },
            set: { isPresented in
                if !isPresented { pendingPaneCloseTarget = nil }
            }
        )
    }

    var supermuxPaneActions: SupermuxWorkspacePaneActions? {
        SupermuxWorkspacePaneActions(connection: store.supermuxConnectionSeam)
    }

    var activePaneCloseTarget: WorkspacePaneCloseTarget? {
        activeSurface.paneCloseTarget(
            selectedTerminalID: selectedTerminalID,
            browserStreamPanelID: activeBrowserStream?.id,
            simulatorStreamPanelID: activeSimulatorStream?.id
        )
    }

    var canCloseActivePane: Bool {
        guard let activePaneCloseTarget else { return false }
        switch activePaneCloseTarget {
        case .localBrowser:
            return true
        case .remote:
            return supermuxPaneActions != nil
        }
    }

    var canCreateSimulatorPane: Bool {
        supermuxPaneActions != nil
            && store.supportsSimulatorStream
            && simulatorCreateRequest == nil
    }

    func requestClosePane() {
        guard canCloseActivePane, let activePaneCloseTarget else { return }
        dismissTerminalKeyboardForChrome()
        pendingPaneCloseTarget = activePaneCloseTarget
    }

    func confirmClosePane() {
        guard let target = pendingPaneCloseTarget else { return }
        pendingPaneCloseTarget = nil
        switch target {
        case .localBrowser:
            browserStore.closeBrowser(for: workspace.id.rawValue)
        case .remote(let panelID):
            guard let actions = supermuxPaneActions else {
                presentPaneActionFailure(SupermuxWorkspacePaneActions.closeFailureMessage)
                return
            }
            let workspaceID = workspace.rpcWorkspaceID.rawValue
            Task { @MainActor in
                do {
                    guard try await actions.closePane(
                        workspaceID: workspaceID,
                        panelID: panelID
                    ) else {
                        presentPaneActionFailure(SupermuxWorkspacePaneActions.closeFailureMessage)
                        return
                    }
                } catch {
                    presentPaneActionFailure(SupermuxWorkspacePaneActions.closeFailureMessage)
                }
            }
        }
    }

    func createSimulatorFromToolbar() {
        guard let actions = supermuxPaneActions,
              store.supportsSimulatorStream,
              simulatorCreateRequest == nil else { return }
        dismissTerminalKeyboardForChrome()
        browserCreateRequest = nil
        let request = UUID()
        simulatorCreateRequest = request
        let workspaceID = workspace.rpcWorkspaceID.rawValue
        Task { @MainActor in
            do {
                let descriptor = try await actions.createSimulatorPane(
                    workspaceID: workspaceID
                )
                guard simulatorCreateRequest == request else { return }
                simulatorCreateRequest = nil
                simulatorStreamStore.applySimulatorDescriptor(descriptor)
                selectSimulatorStreamFromToolbar(descriptor.panelID)
            } catch {
                guard simulatorCreateRequest == request else { return }
                simulatorCreateRequest = nil
                presentPaneActionFailure(
                    SupermuxWorkspacePaneActions.simulatorCreateFailureMessage
                )
            }
        }
    }

    private func presentPaneActionFailure(_ message: String) {
        if toasts.isEnabled {
            toasts.present(.failure(message))
        } else {
            MobileHapticFeedback().notification(.error)
        }
    }
}
// SUPERMUX:end ios-pane-actions
