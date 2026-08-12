/// The launcher persisted for one Claude harness session.
///
/// Plain Claude and ccx use compact string values on the wire. A custom
/// launcher uses `{ "custom": "/absolute/path" }`, preserving the exact path
/// that resume must reuse.
public enum SupermuxClaudeLauncher: Codable, Sendable, Equatable {
    /// The `claude` executable resolved by the Mac host.
    case claude
    /// The user's ccx wrapper.
    case ccx
    /// A user-selected executable at an absolute path.
    case custom(path: String)

    private enum KnownValue: String, Codable {
        case claude
        case ccx
    }

    private enum CodingKeys: String, CodingKey {
        case custom
    }

    /// Decodes a launcher from its compact wire representation.
    /// - Parameter decoder: The decoder supplying a launcher string or custom object.
    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let known = try? container.decode(KnownValue.self) {
            switch known {
            case .claude: self = .claude
            case .ccx: self = .ccx
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .custom(path: try container.decode(String.self, forKey: .custom))
    }

    /// Encodes the launcher using the compact string-or-object wire shape.
    /// - Parameter encoder: The encoder receiving the launcher representation.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .claude:
            var container = encoder.singleValueContainer()
            try container.encode(KnownValue.claude)
        case .ccx:
            var container = encoder.singleValueContainer()
            try container.encode(KnownValue.ccx)
        case .custom(let path):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .custom)
        }
    }
}
