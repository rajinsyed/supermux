public import CMUXMobileCore
public import CmuxMobileRPC
import SupermuxMobileKit

/// Capability-gated pane actions for one connected workspace detail view.
public struct SupermuxWorkspacePaneActions: Sendable {
    private let client: SupermuxMacClient

    /// Creates pane actions only when the connected host advertises support.
    /// - Parameter connection: The shell's live RPC client and capability snapshot.
    public init?(
        connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?
    ) {
        guard let connection else { return nil }
        let capabilities = SupermuxMobileCapabilities(
            hostCapabilities: connection.hostCapabilities
        )
        guard capabilities.supportsPanes else { return nil }
        client = SupermuxMacClient(client: connection.rpcClient)
    }

    /// Closes one remote panel through the Mac's shared panel close path.
    /// - Parameters:
    ///   - workspaceID: The Mac-local workspace identifier.
    ///   - panelID: The terminal, browser, Simulator, or other panel identifier.
    /// - Returns: Whether the Mac completed the close.
    public func closePane(
        workspaceID: String,
        panelID: String
    ) async throws -> Bool {
        try await client.closePane(SupermuxPaneCloseRequest(
            workspaceID: workspaceID,
            panelID: panelID
        )).closed
    }

    /// Creates a native Simulator panel in the workspace.
    /// - Parameter workspaceID: The Mac-local workspace identifier.
    /// - Returns: The descriptor used to activate the new stream immediately.
    public func createSimulatorPane(
        workspaceID: String
    ) async throws -> MobileSimulatorPanelDescriptor {
        try await client.createSimulatorPane(
            SupermuxSimulatorCreateRequest(workspaceID: workspaceID)
        )
    }

    /// Localized failure text for a rejected pane close.
    public static var closeFailureMessage: String {
        String(
            localized: "supermux.panes.closeFailed",
            defaultValue: "Couldn’t close the pane.",
            bundle: .module
        )
    }

    /// Localized failure text for a rejected Simulator creation.
    public static var simulatorCreateFailureMessage: String {
        String(
            localized: "supermux.panes.simulatorCreateFailed",
            defaultValue: "Couldn’t create the Simulator pane.",
            bundle: .module
        )
    }
}
