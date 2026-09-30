public import Foundation

/// Where a notification's project icon is looked up.
///
/// A project id is minted by the Mac that owns the project, and project sync
/// never copies ids between Macs. A notification mirrored from another Mac
/// carries THAT Mac's project, so its id means nothing in this Mac's icon
/// store; the icon comes from the other Mac's fetched icons instead. Looking it
/// up locally silently falls back to the generated chip on two real Macs
/// (loopback, where both "Macs" share one project list, hides the miss).
public enum SupermuxNotificationIconSource: Hashable, Sendable {
    /// One of this Mac's projects.
    case local(projectID: UUID)
    /// Another Mac's project, keyed by that Mac's machine id.
    case remote(machineID: String, projectID: UUID)

    /// The icon lookup for a notification's project, or `nil` for an id that
    /// is not a project UUID.
    /// - Parameters:
    ///   - projectID: The notification's `SupermuxNotificationProject.id`.
    ///   - mirroredFromMachineID: The other Mac's machine id when the
    ///     notification was mirrored from it; `nil` (or blank) for a
    ///     notification from this Mac.
    public init?(projectID: String, mirroredFromMachineID: String?) {
        guard let id = UUID(uuidString: projectID) else { return nil }
        let machineID = mirroredFromMachineID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self = machineID.isEmpty ? .local(projectID: id) : .remote(machineID: machineID, projectID: id)
    }
}
