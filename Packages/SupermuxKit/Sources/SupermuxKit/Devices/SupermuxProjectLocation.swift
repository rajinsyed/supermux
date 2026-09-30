public import Foundation

/// Another Mac ("device") that can host copies of projects, as the project
/// UI needs it: its catalog machine id, friendly name and link state.
public struct SupermuxProjectDevice: Hashable, Sendable {
    /// The catalog machine id, `device:<uuid>@<tag>`.
    public let machineID: String
    /// The Mac's friendly name.
    public let name: String
    /// Whether the link to the Mac is live (RPCs work).
    public let isOnline: Bool

    /// Creates a device description.
    public init(machineID: String, name: String, isOnline: Bool) {
        self.machineID = machineID
        self.name = name
        self.isOnline = isOnline
    }
}

/// One Mac's copy of a project: which Mac, that Mac's own project id, and the
/// root path there.
///
/// A project id is only meaningful on its own Mac. Address a remote copy with
/// ``projectID`` in RPCs to ``device`` (never look it up in this Mac's
/// projects), and a local copy through `SupermuxProjectsModel`.
public struct SupermuxProjectLocation: Identifiable, Hashable, Sendable {
    /// Where the copy lives.
    public enum Place: Hashable, Sendable {
        /// This Mac (`SupermuxProjectsModel.projects`).
        case thisMac
        /// Another Mac, reached over its device link.
        case device(SupermuxProjectDevice)
    }

    /// Where the copy lives.
    public let place: Place
    /// The project's id on that Mac.
    public let projectID: UUID
    /// The project's root path on that Mac.
    public let rootPath: String

    /// Creates a location.
    public init(place: Place, projectID: UUID, rootPath: String) {
        self.place = place
        self.projectID = projectID
        self.rootPath = rootPath
    }

    /// Unique per Mac and project: `local:<uuid>` or `<machine>:<uuid>`.
    public var id: String {
        "\(machineID ?? "local"):\(projectID.uuidString)"
    }

    /// Whether the copy is on this Mac.
    public var isThisMac: Bool {
        if case .thisMac = place { return true }
        return false
    }

    /// The remote Mac, or `nil` for this Mac.
    public var device: SupermuxProjectDevice? {
        if case .device(let device) = place { return device }
        return nil
    }

    /// The remote Mac's machine id, or `nil` for this Mac.
    public var machineID: String? { device?.machineID }

    /// Whether the copy is reachable now (this Mac always is).
    public var isOnline: Bool { device?.isOnline ?? true }
}
