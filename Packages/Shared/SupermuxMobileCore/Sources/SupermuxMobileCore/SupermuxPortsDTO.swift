/// Wire representation of a `ports.list` result: the ports another of the
/// user's Macs can forward from this Mac.
public struct SupermuxPortsListDTO: Codable, Sendable, Equatable {
    /// One port a cmux workspace on this Mac listens on, reachable from loopback.
    public struct Port: Codable, Sendable, Equatable {
        public let port: Int
        /// The workspace's id (`Workspace.id`).
        public let workspaceID: String
        /// The workspace's title.
        public let workspaceTitle: String?
        /// The listening terminal's title (usually the running command); nil
        /// for a port the workspace's agent reported.
        public let terminalTitle: String?

        /// Creates one workspace port.
        /// - Parameters:
        ///   - port: The TCP port.
        ///   - workspaceID: The workspace's id.
        ///   - workspaceTitle: The workspace's title.
        ///   - terminalTitle: The listening terminal's title.
        public init(port: Int, workspaceID: String, workspaceTitle: String?, terminalTitle: String?) {
            self.port = port
            self.workspaceID = workspaceID
            self.workspaceTitle = workspaceTitle
            self.terminalTitle = terminalTitle
        }

        private enum CodingKeys: String, CodingKey {
            case port
            case workspaceID = "workspace_id"
            case workspaceTitle = "workspace_title"
            case terminalTitle = "terminal_title"
        }
    }

    /// The workspaces' ports, one entry per port and workspace.
    public let ports: [Port]
    /// Every other loopback listener's port, in no workspace; only when the
    /// request asked for `include_other`.
    public let otherPorts: [Int]?

    /// Creates a `ports.list` result.
    /// - Parameters:
    ///   - ports: The workspaces' ports.
    ///   - otherPorts: The other loopback listeners' ports, when asked for.
    public init(ports: [Port], otherPorts: [Int]? = nil) {
        self.ports = ports
        self.otherPorts = otherPorts
    }

    private enum CodingKeys: String, CodingKey {
        case ports
        case otherPorts = "other_ports"
    }
}
