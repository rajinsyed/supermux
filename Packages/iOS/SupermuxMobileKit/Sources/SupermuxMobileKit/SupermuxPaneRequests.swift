import Foundation
import SupermuxMobileCore

/// A request to close one panel in a workspace on the paired Mac.
public struct SupermuxPaneCloseRequest: Equatable, Sendable {
    /// The Mac-local workspace identifier.
    public let workspaceID: String
    /// The panel identifier to close.
    public let panelID: String

    /// Creates a pane-close request.
    /// - Parameters:
    ///   - workspaceID: The Mac-local workspace identifier.
    ///   - panelID: The panel identifier to close.
    public init(workspaceID: String, panelID: String) {
        self.workspaceID = workspaceID
        self.panelID = panelID
    }

    /// The exact RPC method served by the supermux Mac host.
    public var wireMethod: String { SupermuxMobileMethod.paneClose.rawValue }
    /// The exact snake-case request payload.
    public var wireParams: [String: Any] {
        [
            "workspace_id": workspaceID,
            "panel_id": panelID,
        ]
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.workspaceID == rhs.workspaceID && lhs.panelID == rhs.panelID
    }
}

/// The acknowledgement returned after the paired Mac closes a panel.
public struct SupermuxPaneCloseResponse: Decodable, Equatable, Sendable {
    /// Whether the Mac accepted and completed the close.
    public let closed: Bool
    /// The workspace that owned the closed panel.
    public let workspaceID: String
    /// The closed panel identifier.
    public let panelID: String

    private enum CodingKeys: String, CodingKey {
        case closed
        case workspaceID = "workspace_id"
        case panelID = "panel_id"
    }
}

/// A request to create a native Simulator panel in a workspace on the paired Mac.
public struct SupermuxSimulatorCreateRequest: Equatable, Sendable {
    /// The Mac-local workspace identifier.
    public let workspaceID: String

    /// Creates a Simulator-pane request.
    /// - Parameter workspaceID: The Mac-local workspace identifier.
    public init(workspaceID: String) {
        self.workspaceID = workspaceID
    }

    /// The exact RPC method served by the supermux Mac host.
    public var wireMethod: String { SupermuxMobileMethod.simulatorCreate.rawValue }
    /// The exact snake-case request payload.
    public var wireParams: [String: Any] { ["workspace_id": workspaceID] }
}
