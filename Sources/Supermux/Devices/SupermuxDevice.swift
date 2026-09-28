import CmuxSurfaceCatalogModel
import Foundation

/// A remote Mac's link, reduced to what Supermux UI and coordinators act on.
enum SupermuxDeviceLinkState: String, Sendable {
    /// The link is live; RPCs and mirrors work.
    case connected
    /// The link is dialing or backing off before a redial.
    case connecting
    /// Anything else: offline, unpaired, blocked, other account.
    case offline
}

/// One remote Mac ("device") as the fork sees it: a `.device` machine in
/// `SurfaceCatalog.shared` backed by a `DeviceSurfaceProvider` (real devices
/// and the DEBUG loopback device alike).
struct SupermuxDevice: Identifiable, Hashable, Sendable {
    /// The catalog machine (`device:<uuid>@<tag>`).
    let machine: SurfaceMachineID
    /// The remote app instance.
    let instance: SurfaceDeviceInstanceID
    /// The Mac's friendly name.
    let displayName: String
    let linkState: SupermuxDeviceLinkState
    /// The catalog's link detail (a failure or waiting reason), if any.
    let linkDetail: String?
    /// Whether the synced workspace records were fetched since the link last
    /// connected. Until then records may be stale (or empty), so coordinators
    /// must not close local mirrors because a record is missing.
    let hasFetchedRecords: Bool
    /// The DEBUG loopback device (this app talking to its own mobile host).
    let isLoopback: Bool

    var id: String { machine.rawValue }
    var isConnected: Bool { linkState == .connected }
}
