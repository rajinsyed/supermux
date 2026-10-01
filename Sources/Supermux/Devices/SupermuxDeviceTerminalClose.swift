import Bonsplit
import CmuxSurfaceCatalogModel
import Foundation

/// How this Mac asks another Mac to close one of its terminals
/// (`mobile.terminal.close`), for every close path of
/// ``DeviceWorkspaceLayoutCoordinator`` (the `device-terminal-close-confirm`
/// touchpoint).
///
/// - A close that ends the terminal by definition (Kill Terminal…, which
///   already confirmed that the process ends on the machine; `vm.terminal_close`;
///   a workspace deletion) sends `force: true`, as Cloud does.
/// - A mirror tab's close asks without force. The owning Mac answers
///   `confirmation_required` when its own close-confirmation rule says a
///   program is running; this Mac then shows "Close “X” on <Mac>?". Close
///   resends with force; Cancel throws ``Declined``, which the coordinator
///   turns into a restored tab without a failure card.
@MainActor
enum SupermuxDeviceTerminalClose {
    /// The user kept the terminal running.
    struct Declined: Error {}

    static func request(
        surfaceID: String,
        remoteWorkspaceID: String,
        machine: SurfaceMachineID,
        asksFirst: Bool,
        localWorkspaceID: UUID?,
        catalog: SurfaceCatalog?,
        send: @MainActor (String, [String: Any]) async throws -> Data
    ) async throws -> Data {
        var params: [String: Any] = ["workspace_id": remoteWorkspaceID, "surface_id": surfaceID]
        guard asksFirst else {
            params["force"] = true
            return try await send("mobile.terminal.close", params)
        }
        do {
            return try await send("mobile.terminal.close", params)
        } catch let DeviceLinkError.hostRejected(code, _) where code == "confirmation_required" {
            try Task.checkCancellation()
            let confirmed = await SupermuxDeviceTerminalClosePrompt.ask(
                terminalTitle: terminalTitle(surfaceID: surfaceID, machine: machine, catalog: catalog),
                deviceName: deviceName(machine: machine, catalog: catalog),
                window: localWorkspaceID.flatMap { AppDelegate.shared?.tabManagerFor(tabId: $0)?.window }
            )
            guard confirmed else { throw Declined() }
            try Task.checkCancellation()
            params["force"] = true
            return try await send("mobile.terminal.close", params)
        }
    }

    private static func terminalTitle(surfaceID: String, machine: SurfaceMachineID, catalog: SurfaceCatalog?) -> String {
        let resource = catalog?.resources[SurfaceResourceID(machine: machine, kind: .terminal, key: surfaceID)]
        let title = resource?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty
            ? String(localized: "supermux.devices.terminalClose.untitled", defaultValue: "Terminal")
            : title
    }

    private static func deviceName(machine: SurfaceMachineID, catalog: SurfaceCatalog?) -> String {
        SupermuxComposition.devices.device(for: machine)?.displayName
            ?? catalog?.machines[machine]?.name
            ?? machine.rawValue
    }
}

/// Which other-Mac tabs were selected as they closed, so a close the user
/// cancels in "Close “X” on <Mac>?" brings the tab back selected (the
/// `device-close-cancel-restores-tab` touchpoint).
///
/// The mirror tab leaves the strip when it is closed, before the other Mac
/// answers that a program is running there; Cancel then brings the terminal
/// back as a new pane, which the layout puts back at its place in the strip
/// but which nothing selected, so the neighbour that took over stayed selected.
@MainActor
final class SupermuxDeviceClosedTabs {
    static let shared = SupermuxDeviceClosedTabs()

    private struct Key: Hashable {
        let workspaceID: UUID
        let surfaceKey: String
    }

    /// Closed device tabs that were selected in their pane, with when they closed.
    private var selected: [Key: Date] = [:]

    /// A tab is closing: remembers whether it was its pane's selected tab when
    /// it shows another Mac's terminal.
    func noteClosing(_ tab: TabID, inPane pane: PaneID, workspace: Workspace) {
        guard let panelID = workspace.panelIdFromSurfaceId(tab),
              let projection = SurfaceCatalog.shared.projection(forPanel: panelID),
              projection.resource.machine.isDevice else { return }
        let key = Key(workspaceID: workspace.id, surfaceKey: projection.resource.key.lowercased())
        if workspace.bonsplitController.selectedTab(inPane: pane)?.id == tab {
            selected[key] = Date()
        } else {
            selected[key] = nil
        }
    }

    /// The close of `surfaceKey` was cancelled: once the terminal is shown
    /// again (within a few seconds), selects it if its tab was selected.
    func closeDeclined(surfaceKey: String, workspaceID: UUID, machine: SurfaceMachineID) {
        let key = Key(workspaceID: workspaceID, surfaceKey: surfaceKey.lowercased())
        guard let closedAt = selected.removeValue(forKey: key), Date().timeIntervalSince(closedAt) < 600 else { return }
        Task { @MainActor in
            for _ in 0..<50 {
                if Self.selectRestoredTab(key: key, machine: machine) { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private static func selectRestoredTab(key: Key, machine: SurfaceMachineID) -> Bool {
        guard let workspace = Workspace.liveWorkspace(id: key.workspaceID),
              let projection = SurfaceCatalog.shared.projections.first(where: {
                  $0.workspaceID == key.workspaceID && $0.resource.machine == machine
                      && $0.resource.key.lowercased() == key.surfaceKey
              }),
              let tab = workspace.surfaceIdFromPanelId(projection.panelID),
              let pane = workspace.paneId(forPanelId: projection.panelID) else { return false }
        workspace.bonsplitController.focusPane(pane)
        workspace.bonsplitController.selectTab(tab)
        return true
    }
}
