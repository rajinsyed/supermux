public import Foundation

/// One project row in the Mac sidebar, merged across Macs: this Mac's copy
/// (if any) plus every device's copy of the same repository.
///
/// ``id`` is stable: a project with a copy on this Mac keeps the local
/// project's id (so existing nesting, association and expansion state keep
/// working), and a remote-only project gets a derived id
/// (``SupermuxUnifiedProjects/remoteOnlyID(machineID:projectID:)``), never
/// the remote Mac's own project id.
public struct SupermuxUnifiedProject: Identifiable, Hashable, Sendable {
    /// Stable unified id (see the type docs).
    public let id: UUID
    /// Display name: this Mac's copy's name, else the remote copy's.
    public let name: String
    /// Accent color as `#RRGGBB` from the display copy.
    public let colorHex: String?
    /// SF Symbol avatar from the display copy.
    public let iconSymbol: String?
    /// The normalized origin (`host/owner/repo`) shared by the copies, if known.
    public let gitRemoteIdentity: String?
    /// Every copy: this Mac first, then devices in device order.
    public let locations: [SupermuxProjectLocation]

    /// Creates a unified project.
    public init(
        id: UUID,
        name: String,
        colorHex: String?,
        iconSymbol: String?,
        gitRemoteIdentity: String?,
        locations: [SupermuxProjectLocation]
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.iconSymbol = iconSymbol
        self.gitRemoteIdentity = gitRemoteIdentity
        self.locations = locations
    }

    /// This Mac's copy, if any.
    public var localLocation: SupermuxProjectLocation? { locations.first(where: \.isThisMac) }

    /// This Mac's project id, if it has a copy.
    public var localProjectID: UUID? { localLocation?.projectID }

    /// The copies on other Macs.
    public var remoteLocations: [SupermuxProjectLocation] { locations.filter { !$0.isThisMac } }

    /// Whether only other Macs have a copy.
    public var isRemoteOnly: Bool { localLocation == nil }

    /// The copy on one device, if it has one.
    public func location(onMachine machineID: String) -> SupermuxProjectLocation? {
        locations.first { $0.machineID == machineID }
    }

    /// The given devices that have no copy (the "Set Up on <Mac>…" targets).
    public func devicesLacking(among devices: [SupermuxProjectDevice]) -> [SupermuxProjectDevice] {
        let present = Set(locations.compactMap(\.machineID))
        return devices.filter { !present.contains($0.machineID) }
    }
}
