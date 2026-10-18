public import Foundation
public import SupermuxMobileCore

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
    /// The project's effective place in the shared order: the stamp that wins
    /// among its copies' stamps (``SupermuxOrderStamp/wins(over:)``), or
    /// `nil` while no copy is stamped. Every device sorts by it
    /// (``SupermuxUnifiedProjectList/sharedOrder``).
    public let order: SupermuxOrderStamp?

    /// Creates a unified project.
    public init(
        id: UUID,
        name: String,
        colorHex: String?,
        iconSymbol: String?,
        gitRemoteIdentity: String?,
        locations: [SupermuxProjectLocation],
        order: SupermuxOrderStamp? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.iconSymbol = iconSymbol
        self.gitRemoteIdentity = gitRemoteIdentity
        self.locations = locations
        self.order = order
    }

    /// This Mac's copy, if any.
    public var localLocation: SupermuxProjectLocation? { locations.first(where: \.isThisMac) }

    /// This Mac's project id, if it has a copy.
    public var localProjectID: UUID? { localLocation?.projectID }

    /// The copies on other Macs.
    public var remoteLocations: [SupermuxProjectLocation] { locations.filter { !$0.isThisMac } }

    /// Whether only other Macs have a copy.
    public var isRemoteOnly: Bool { localLocation == nil }

    /// Whether a move can stamp the project now: a copy takes an order stamp
    /// (``SupermuxProjectLocation/takesOrderStamp``). Only such a project drags.
    public var takesOrderStamp: Bool { locations.contains(where: \.takesOrderStamp) }

    /// Whether the project has a place in the keyed shared order: it is
    /// stamped, or a move can stamp it. A project that is neither (only an
    /// older Mac, or an offline one that never stamped it, holds it) sorts
    /// after the keyed ones, and no move stamps it or places a row after it.
    public var isOrderKeyed: Bool { order != nil || takesOrderStamp }

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
