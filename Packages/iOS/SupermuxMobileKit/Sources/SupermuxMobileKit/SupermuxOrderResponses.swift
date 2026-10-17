public import SupermuxMobileCore

/// `mobile.supermux.workspace.set_order` result: `{workspace_id, order_key}`.
public struct SupermuxWorkspaceSetOrderResponse: Codable, Sendable, Equatable {
    /// The workspace the Mac moved.
    public var workspaceID: String
    /// The key the Mac holds after the move: the sent key, or another one
    /// when its pins or groups clamped the drop.
    public var orderKey: String

    /// Creates a response value (used by tests and fakes).
    /// - Parameters:
    ///   - workspaceID: The workspace the Mac moved.
    ///   - orderKey: The key the Mac holds after the move.
    public init(workspaceID: String, orderKey: String) {
        self.workspaceID = workspaceID
        self.orderKey = orderKey
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case orderKey = "order_key"
    }
}

/// `mobile.supermux.projects.set_order` result: one result per sent stamp.
public struct SupermuxProjectsSetOrderResponse: Codable, Sendable, Equatable {
    /// What the Mac did with one copy's stamp.
    public struct Result: Codable, Sendable, Equatable {
        /// That Mac's own project id.
        public var projectID: String
        /// Whether the stamp replaced the copy's (it was newer).
        public var applied: Bool
        /// The copy's stamp now, or `nil` when the copy is unknown.
        public var order: SupermuxOrderStamp?
        /// `not_found` for an unknown copy, otherwise `nil`.
        public var error: String?

        /// Creates a result value (used by tests and fakes).
        /// - Parameters:
        ///   - projectID: That Mac's own project id.
        ///   - applied: Whether the stamp replaced the copy's.
        ///   - order: The copy's stamp now.
        ///   - error: The per-copy error code, if any.
        public init(projectID: String, applied: Bool, order: SupermuxOrderStamp? = nil, error: String? = nil) {
            self.projectID = projectID
            self.applied = applied
            self.order = order
            self.error = error
        }

        private enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case applied
            case order
            case error
        }
    }

    /// One result per sent stamp.
    public var results: [Result]

    /// Creates a response value (used by tests and fakes).
    /// - Parameter results: One result per sent stamp.
    public init(results: [Result]) {
        self.results = results
    }
}
