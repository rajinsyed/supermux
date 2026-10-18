public import SupermuxMobileCore

/// `mobile.supermux.workspace.set_order`: asks the Mac that owns a workspace
/// to give it a new shared order key and move it there in its own sidebar.
///
/// Only the owner writes a workspace's key, so a phone drag across Macs asks
/// the owner instead of moving anything itself. The owner answers with the
/// key it holds after the move, which can differ when its pins or groups
/// clamp the drop.
///
/// ```swift
/// let request = SupermuxWorkspaceSetOrderRequest(workspaceID: row.rpcWorkspaceID.rawValue, orderKey: key, isPinned: row.isPinned)
/// let reply = try await client.workspaceSetOrder(request)
/// ```
public struct SupermuxWorkspaceSetOrderRequest: Equatable, Sendable {
    /// The owner Mac's own workspace id.
    public let workspaceID: String
    /// The new ``SupermuxOrderKey`` for the workspace.
    public let orderKey: String
    /// Whether the phone saw the row pinned. The owner refuses with
    /// `conflict` when its pin changed meanwhile.
    public let isPinned: Bool

    /// Creates the request.
    /// - Parameters:
    ///   - workspaceID: The owner Mac's own workspace id.
    ///   - orderKey: The new order key.
    ///   - isPinned: Whether the phone saw the row pinned.
    public init(workspaceID: String, orderKey: String, isPinned: Bool) {
        self.workspaceID = workspaceID
        self.orderKey = orderKey
        self.isPinned = isPinned
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.workspaceSetOrder.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        ["workspace_id": workspaceID, "order_key": orderKey, "is_pinned": isPinned]
    }
}

/// `mobile.supermux.projects.set_order`: gives copies of projects on one Mac
/// new order stamps. The Mac keeps a stamp only when it is newer than the
/// copy's, so sending one again changes nothing.
public struct SupermuxProjectsSetOrderRequest: Equatable, Sendable {
    /// One copy's new stamp.
    public struct Entry: Equatable, Sendable {
        /// That Mac's own project id.
        public let projectID: String
        /// The copy's new stamp.
        public let order: SupermuxOrderStamp

        /// Creates an entry.
        /// - Parameters:
        ///   - projectID: That Mac's own project id.
        ///   - order: The copy's new stamp.
        public init(projectID: String, order: SupermuxOrderStamp) {
            self.projectID = projectID
            self.order = order
        }
    }

    /// The stamps, one per project copy on this Mac.
    public let stamps: [Entry]

    /// Creates the request.
    /// - Parameter stamps: The stamps, one per project copy on this Mac.
    public init(stamps: [Entry]) {
        self.stamps = stamps
    }

    /// The exact wire method string.
    public var wireMethod: String { SupermuxMobileMethod.projectsSetOrder.rawValue }

    /// The exact wire params.
    public var wireParams: [String: Any] {
        [
            "stamps": stamps.map { entry in
                [
                    "project_id": entry.projectID,
                    "order": [
                        "key": entry.order.key,
                        "updated_at": entry.order.updatedAt,
                        "origin": entry.order.origin,
                    ] as [String: Any],
                ] as [String: Any]
            },
        ]
    }
}
