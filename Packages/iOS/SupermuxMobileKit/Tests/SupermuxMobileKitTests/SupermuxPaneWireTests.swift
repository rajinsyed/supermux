import CMUXMobileCore
import Foundation
import SupermuxMobileKit
import Testing

@Suite struct SupermuxPaneWireTests {
    @Test func paneCloseRequestCarriesWorkspaceAndPanelIDs() {
        let request = SupermuxPaneCloseRequest(
            workspaceID: "workspace-1",
            panelID: "panel-1"
        )

        #expect(request.wireMethod == "mobile.supermux.pane.close")
        #expect(request.wireParams as NSDictionary == [
            "workspace_id": "workspace-1",
            "panel_id": "panel-1",
        ] as NSDictionary)
    }

    @Test func paneCloseResponseDecodesTheMacAcknowledgement() throws {
        let response = try JSONDecoder().decode(
            SupermuxPaneCloseResponse.self,
            from: Data(#"{"closed":true,"workspace_id":"workspace-1","panel_id":"panel-1"}"#.utf8)
        )

        #expect(response.closed)
        #expect(response.workspaceID == "workspace-1")
        #expect(response.panelID == "panel-1")
    }

    @Test func simulatorCreateRequestCarriesOnlyTheWorkspaceID() {
        let request = SupermuxSimulatorCreateRequest(workspaceID: "workspace-1")

        #expect(request.wireMethod == "mobile.supermux.simulator.create")
        #expect(request.wireParams as NSDictionary == [
            "workspace_id": "workspace-1",
        ] as NSDictionary)
    }

    @Test func simulatorCreateResponseDecodesForImmediateStreamActivation() throws {
        let descriptor = try JSONDecoder().decode(
            MobileSimulatorPanelDescriptor.self,
            from: Data("""
            {
              "panel_id": "simulator-1",
              "workspace_id": "workspace-1",
              "title": "Simulator",
              "selected_device_name": null,
              "selected_device_state": null,
              "status": "idle",
              "is_ready": false,
              "supports_touch": true,
              "supports_keyboard": true,
              "supports_hardware_buttons": true,
              "supports_rotation": true,
              "owner_connection_id": null,
              "is_owned_by_current_connection": null
            }
            """.utf8)
        )

        #expect(descriptor.panelID == "simulator-1")
        #expect(descriptor.workspaceID == "workspace-1")
        #expect(descriptor.supportsTouch)
        #expect(descriptor.supportsKeyboard)
    }
}
