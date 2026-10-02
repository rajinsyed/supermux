import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// The owning Mac's simulator calls a remote-simulator viewer makes over the
/// device link, all within one remote workspace: upstream's
/// `mobile.simulator.*` (listing panels and devices, picking a device,
/// recovery) and the fork's `simulator.create`, `simulator.control` and
/// `pane.close`.
@MainActor
struct SupermuxRemoteSimulatorHostClient {
    /// One simulator in the owning Mac's device menu.
    struct Device: Equatable, Sendable {
        let udid: String
        let name: String
        let state: String
        let isSelected: Bool
    }

    let machine: SurfaceMachineID
    let workspaceID: String

    private var devices: SupermuxDevices { SupermuxComposition.devices }

    /// The workspace's Simulator panels there, in tab order.
    func panelIDs() async throws -> [UUID] {
        let result = try await devices.request("mobile.simulator.list", params: ["workspace_id": workspaceID], on: machine)
        let panels = result["panels"] as? [[String: Any]] ?? []
        return panels.compactMap { ($0["panel_id"] as? String).flatMap(UUID.init(uuidString:)) }
    }

    /// The simulators `panelID` can show, booted first (a fresh `simctl list`
    /// there), with the one it shows marked.
    func deviceList(panelID: UUID) async throws -> [Device] {
        let result = try await devices.request(
            "mobile.simulator.devices.list",
            params: params(panelID),
            on: machine
        )
        return (result["devices"] as? [[String: Any]] ?? []).compactMap { row in
            guard let udid = row["udid"] as? String else { return nil }
            return Device(
                udid: udid,
                name: row["name"] as? String ?? udid,
                state: row["state"] as? String ?? "",
                isSelected: row["is_selected"] as? Bool ?? false
            )
        }
    }

    /// Shows `udid` in `panelID`, booting it there when needed (the host
    /// answers before the boot finishes; the stream reports progress).
    func select(udid: String, panelID: UUID) async throws {
        var params = params(panelID)
        params["udid"] = udid
        _ = try await devices.request("mobile.simulator.device.select", params: params, on: machine)
    }

    /// Restarts a crashed simulator worker there.
    func recover(panelID: UUID) async throws {
        _ = try await devices.request("mobile.simulator.recover", params: params(panelID), on: machine)
    }

    /// Opens a new Simulator tab in the workspace there (in the background)
    /// and returns its panel id. `udid` picks its device.
    func create(udid: String?) async throws -> UUID {
        var params: [String: Any] = ["workspace_id": workspaceID, "focus": false]
        if let udid { params["udid"] = udid }
        let result = try await devices.request(.simulatorCreate, params: params, on: machine)
        guard let panelID = (result["panel_id"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw SupermuxDeviceError.malformedResponse(SupermuxMobileMethod.simulatorCreate.rawValue)
        }
        return panelID
    }

    /// Runs a toolbar control there: `rotate_left`, `rotate_right`,
    /// `toggle_software_keyboard` or `toggle_appearance`.
    func control(_ action: String, panelID: UUID) async throws {
        var params = params(panelID)
        params["action"] = action
        _ = try await devices.request(.simulatorControl, params: params, on: machine)
    }

    /// Closes the Simulator tab there (its device keeps running).
    func close(panelID: UUID) async throws {
        _ = try await devices.request(.paneClose, params: params(panelID), on: machine)
    }

    private func params(_ panelID: UUID) -> [String: Any] {
        ["workspace_id": workspaceID, "panel_id": panelID.uuidString]
    }
}
