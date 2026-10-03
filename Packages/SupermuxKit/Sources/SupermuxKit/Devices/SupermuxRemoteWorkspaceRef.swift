public import Foundation

/// One workspace on another Mac: the device's catalog machine id plus the
/// remote workspace id its host reports.
///
/// `machineID` is the catalog wire value `device:<uuid>@<tag>`
/// (`SurfaceMachineID.rawValue` in the app target). `workspaceID` is
/// canonicalized so the same remote workspace compares equal however a path
/// spelled it: records carry uppercase UUIDs, some socket and projection paths
/// lowercase ones. Non-UUID ids are kept verbatim (trimmed).
///
/// ```swift
/// let ref = SupermuxRemoteWorkspaceRef(machineID: "device:…@default", workspaceID: record.id)
/// ```
public struct SupermuxRemoteWorkspaceRef: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The device machine's wire value, `device:<uuid>@<tag>`.
    public let machineID: String
    /// The remote workspace id, canonicalized (uppercase for UUIDs).
    public let workspaceID: String

    /// Creates a ref, canonicalizing both parts.
    /// - Parameters:
    ///   - machineID: The device machine's wire value.
    ///   - workspaceID: The remote workspace id in any case.
    public init(machineID: String, workspaceID: String) {
        self.machineID = machineID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workspaceID = Self.canonicalWorkspaceID(workspaceID)
    }

    /// The canonical spelling of a remote workspace id: an uppercase
    /// `uuidString` when it parses as a UUID, else the trimmed input.
    public static func canonicalWorkspaceID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: trimmed)?.uuidString ?? trimmed
    }

    public var description: String { "\(machineID)/\(workspaceID)" }

    private enum CodingKeys: String, CodingKey {
        case machineID = "machine_id"
        case workspaceID = "workspace_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            machineID: try container.decode(String.self, forKey: .machineID),
            workspaceID: try container.decode(String.self, forKey: .workspaceID)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(machineID, forKey: .machineID)
        try container.encode(workspaceID, forKey: .workspaceID)
    }
}
