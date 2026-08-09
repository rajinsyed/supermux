public import CMUXMobileCore

/// The typed RPC seam for workspace pane actions initiated from the iOS app.
public protocol SupermuxPaneMacCalling: Sendable {
    /// Closes one terminal, browser, Simulator, or other workspace panel.
    /// - Parameter request: The workspace- and panel-scoped close request.
    /// - Returns: The Mac's close acknowledgement.
    func closePane(_ request: SupermuxPaneCloseRequest) async throws -> SupermuxPaneCloseResponse

    /// Creates a native Simulator panel without stealing focus on the Mac.
    /// - Parameter request: The workspace-scoped creation request.
    /// - Returns: The created panel's stream descriptor.
    func createSimulatorPane(
        _ request: SupermuxSimulatorCreateRequest
    ) async throws -> MobileSimulatorPanelDescriptor
}
