import CmuxSurfaceCatalogModel
import Foundation

/// Creates a global (project-less) workspace on another Mac and opens its
/// mirror in the window that asked: the one path behind
/// "New Workspace on ▸ <Mac>" and ⌘N while a device-backed workspace is
/// selected.
///
/// It goes through the foundation's ``SupermuxDeviceWorkspaceOpener`` (remote
/// `workspace.create` first, then the mirror opens already titled and bound),
/// so the provisional "Cloud VM" reservation title upstream's device ⌘N shows
/// during the round trip never renders, and it does not depend on the Cloud
/// Machines operation controller.
@MainActor
final class SupermuxDeviceNewWorkspaceAction {
    private let devices: SupermuxDevices
    private let opener: SupermuxDeviceWorkspaceOpener
    /// One create per (window, Mac) at a time; a repeated ⌘N is absorbed.
    private var inFlight: Set<String> = []

    init(devices: SupermuxDevices, opener: SupermuxDeviceWorkspaceOpener) {
        self.devices = devices
        self.opener = opener
    }

    /// Whether the fork handles creation on `machine` (a known device).
    func handles(_ machine: SurfaceMachineID) -> Bool {
        machine.isDevice && devices.provider(for: machine) != nil
    }

    /// Starts creating a workspace on `machine` in `manager`'s window.
    /// - Returns: `false` when the fork does not own `machine` (the caller
    ///   falls back to upstream), otherwise `true` (the event is consumed).
    @discardableResult
    func start(on machine: SurfaceMachineID, in manager: TabManager) -> Bool {
        guard handles(machine) else { return false }
        let key = "\(ObjectIdentifier(manager).hashValue)|\(machine.rawValue)"
        guard inFlight.insert(key).inserted else { return true }
        let origin = manager.selectedWorkspace
        Task { @MainActor [weak self, weak manager, weak origin] in
            defer { self?.inFlight.remove(key) }
            guard let self, let manager else { return }
            do {
                _ = try await self.create(on: machine, in: manager)
            } catch {
                self.present(error, machine: machine, origin: origin)
            }
        }
        return true
    }

    /// Creates the workspace and returns its mirror; selects it unless the
    /// user navigated elsewhere while it was being created (that wins, as in
    /// upstream's device ⌘N).
    func create(on machine: SurfaceMachineID, in manager: TabManager) async throws -> SupermuxDeviceWorkspaceOpener.Opened {
        let revision = manager.cloudWorkspaceSelection.revision
        let opened = try await opener.createWorkspace(
            on: machine, title: nil, workingDirectory: nil, in: manager, focus: false
        )
        if manager.cloudWorkspaceSelection.revision == revision {
            manager.selectWorkspace(opened.workspace)
            if let first = opened.workspace.focusedPanelId ?? opened.workspace.panels.keys.first {
                opened.workspace.focusPanel(first)
            }
        }
        return opened
    }

    /// Shows the failure on the workspace the request came from (upstream's
    /// pane-local failure strip), like upstream's device ⌘N.
    private func present(_ error: any Error, machine: SurfaceMachineID, origin: Workspace?) {
        guard let origin else { return }
        let store = origin.cloudPaneCreationFailureStore
        let requestID = store.beginRequest()
        store.present(
            machine: machine,
            error: error,
            requestID: requestID,
            title: String(localized: "applescript.error.failedToCreateWorkspace", defaultValue: "Failed to create workspace."),
            recoveryText: String(
                localized: "supermux.mirror.newWorkspace.failed.recovery",
                defaultValue: "Check that the other Mac is online, then try again."
            ),
            sourcePanelID: origin.focusedPanelId
        )
    }
}
