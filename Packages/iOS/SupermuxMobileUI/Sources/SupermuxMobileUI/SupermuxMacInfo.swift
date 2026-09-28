public import SupermuxMobileKit

/// What the Projects section knows about one connected Mac: its pairing
/// identity plus the presentation facts its header shows. A pure value, so
/// the section can be driven by the shell's seams or by tests alike.
public struct SupermuxMacInfo: Equatable, Sendable {
    /// Exact pairing identity (`SupermuxMacSeam.pairingID`); empty for the
    /// anonymous foreground or the single legacy session.
    public let pairingID: String
    /// The Mac's device id, or `nil` when unknown.
    public let macDeviceID: String?
    /// The pairing's build tag, if any.
    public let instanceTag: String?
    /// The Mac's user-facing name.
    public let displayName: String
    /// The shell's stable per-pairing color slot, if assigned.
    public let colorIndex: Int?
    /// The user's color override for this Mac, if any.
    public let customColor: String?
    /// The link's current health.
    public let status: SupermuxMacSeam.Status
    /// Whether this is the foreground (terminal-owning) Mac.
    public let isForeground: Bool

    /// Creates the info.
    /// - Parameters:
    ///   - macDeviceID: The Mac's device id, or `nil` when unknown.
    ///   - instanceTag: The pairing's build tag, if any.
    ///   - displayName: The Mac's user-facing name.
    ///   - colorIndex: The shell's color slot, if assigned.
    ///   - customColor: The user's color override, if any.
    ///   - status: The link's current health.
    ///   - isForeground: Whether this is the foreground Mac.
    public init(
        macDeviceID: String?,
        instanceTag: String?,
        displayName: String,
        colorIndex: Int? = nil,
        customColor: String? = nil,
        status: SupermuxMacSeam.Status = .connected,
        isForeground: Bool = false
    ) {
        self.pairingID = SupermuxMacSeam.pairingID(macDeviceID: macDeviceID, instanceTag: instanceTag)
        self.macDeviceID = macDeviceID
        self.instanceTag = instanceTag
        self.displayName = displayName
        self.colorIndex = colorIndex
        self.customColor = customColor
        self.status = status
        self.isForeground = isForeground
    }

    /// The info for a shell seam.
    /// - Parameter seam: One live Mac pairing from the shell.
    public init(seam: SupermuxMacSeam) {
        self.init(
            macDeviceID: seam.macDeviceID,
            instanceTag: seam.instanceTag,
            displayName: seam.displayName,
            colorIndex: seam.colorIndex,
            customColor: seam.customColor,
            status: seam.status,
            isForeground: seam.isForeground
        )
    }

    /// The single, unidentified Mac of the pre-multi-Mac API.
    static let legacy = SupermuxMacInfo(
        macDeviceID: nil,
        instanceTag: nil,
        displayName: "",
        isForeground: true
    )
}
