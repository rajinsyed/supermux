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
            let confirmed = SupermuxDeviceTerminalClosePrompt.ask(
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
