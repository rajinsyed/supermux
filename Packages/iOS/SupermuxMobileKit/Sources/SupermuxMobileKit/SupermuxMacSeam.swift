import CMUXMobileCore
public import CmuxMobileRPC
import Foundation

/// One live Mac pairing the phone can drive Supermux features on.
///
/// The shell publishes one seam per live pairing — the foreground Mac plus
/// every background ("control") Mac — so the fork's projects, worktree, run
/// and push features can talk to a Mac without making it the foreground.
/// A pure value: the shell owns the connections, this only names them.
public struct SupermuxMacSeam: Sendable {
    /// How healthy the pairing's link currently is.
    public enum Status: Sendable, Equatable {
        /// The link is up and serving requests.
        case connected
        /// The link dropped and the shell is re-establishing it.
        case reconnecting
        /// The Mac is unreachable.
        case unavailable
    }

    /// Exact pairing identity (`CmxMacAppInstanceIdentity.id`): device plus
    /// build tag. Empty only for the anonymous pre-identity foreground.
    public let pairingID: String
    /// The Mac's device id, or `nil` for the anonymous foreground.
    public let macDeviceID: String?
    /// The pairing's build tag ("default", "nightly", a dev tag), if any.
    public let instanceTag: String?
    /// The Mac's user-facing name.
    public let displayName: String
    /// The shell's stable per-pairing color slot, if assigned.
    public let colorIndex: Int?
    /// The user's color override for this Mac (`palette:<n>` or `#RRGGBB`).
    public let customColor: String?
    /// The pairing's RPC client.
    public let client: MobileCoreRPCClient
    /// The raw capability strings this Mac advertises.
    public let hostCapabilities: Set<String>
    /// The link's current health.
    public let status: Status
    /// Whether this is the foreground (terminal-owning) Mac.
    public let isForeground: Bool

    /// Creates a seam.
    /// - Parameters:
    ///   - macDeviceID: The Mac's device id, or `nil` for the anonymous
    ///     foreground.
    ///   - instanceTag: The pairing's build tag, if any.
    ///   - displayName: The Mac's user-facing name.
    ///   - colorIndex: The shell's color slot for the pairing, if assigned.
    ///   - customColor: The user's color override, if any.
    ///   - client: The pairing's RPC client.
    ///   - hostCapabilities: The raw capability strings the Mac advertises.
    ///   - status: The link's current health.
    ///   - isForeground: Whether this is the foreground Mac.
    public init(
        macDeviceID: String?,
        instanceTag: String?,
        displayName: String,
        colorIndex: Int? = nil,
        customColor: String? = nil,
        client: MobileCoreRPCClient,
        hostCapabilities: Set<String>,
        status: Status,
        isForeground: Bool
    ) {
        self.pairingID = Self.pairingID(macDeviceID: macDeviceID, instanceTag: instanceTag)
        self.macDeviceID = macDeviceID
        self.instanceTag = instanceTag
        self.displayName = displayName
        self.colorIndex = colorIndex
        self.customColor = customColor
        self.client = client
        self.hostCapabilities = hostCapabilities
        self.status = status
        self.isForeground = isForeground
    }

    /// The pairing id the shell stamps on this Mac's workspace rows, so a
    /// workspace and a project can be matched to the same Mac.
    /// - Parameters:
    ///   - macDeviceID: The owning Mac's device id, or `nil` when unowned.
    ///   - instanceTag: The owning pairing's build tag, if any.
    public static func pairingID(macDeviceID: String?, instanceTag: String?) -> String {
        guard let macDeviceID, !macDeviceID.isEmpty else { return "" }
        return CmxMacAppInstanceIdentity(macDeviceID: macDeviceID, instanceTag: instanceTag).id
    }
}
