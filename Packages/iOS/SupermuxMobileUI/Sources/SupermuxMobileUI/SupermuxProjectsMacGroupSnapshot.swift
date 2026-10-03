public import SupermuxMobileCore
public import SupermuxMobileKit

/// The header over one Mac's projects when more than one Mac has projects:
/// the Mac's name, its color, and whether its link is healthy.
public struct SupermuxProjectsMacHeader: Equatable, Sendable {
    /// The owning pairing's id.
    public let pairingID: String
    /// The Mac's device id, or `nil` when unknown.
    public let macDeviceID: String?
    /// The pairing's build tag, if any.
    public let instanceTag: String?
    /// The Mac's user-facing name.
    public let displayName: String
    /// The shell's color slot for this Mac, if assigned.
    public let colorIndex: Int?
    /// The user's color override for this Mac, if any.
    public let customColor: String?
    /// The link's current health.
    public let status: SupermuxMacSeam.Status
    /// Whether this is the foreground Mac.
    public let isForeground: Bool

    /// Creates a header from a Mac's info.
    /// - Parameter mac: The Mac the header names.
    public init(mac: SupermuxMacInfo) {
        self.pairingID = mac.pairingID
        self.macDeviceID = mac.macDeviceID
        self.instanceTag = mac.instanceTag
        self.displayName = mac.displayName
        self.colorIndex = mac.colorIndex
        self.customColor = mac.customColor
        self.status = mac.status
        self.isForeground = mac.isForeground
    }
}

/// One Mac's slice of the Projects section: its header, its project rows and
/// the capability-gated affordances THAT Mac supports (presets, actions and
/// worktree creation are per-Mac features).
public struct SupermuxProjectsMacGroupSnapshot: Equatable, Sendable, Identifiable {
    /// The owning pairing's id.
    public var id: String { header.pairingID }
    /// The Mac's header facts.
    public let header: SupermuxProjectsMacHeader
    /// Whether this Mac's projects list has loaded at least once.
    public let hasLoaded: Bool
    /// This Mac's project rows, in its sidebar order.
    public let rows: [SupermuxProjectRowSnapshot]
    /// Whether this Mac serves presets.
    public let showsPresets: Bool
    /// This Mac's global terminal presets.
    public let presets: [SupermuxTerminalPresetDTO]
    /// Whether this Mac serves project actions.
    public let showsActions: Bool
    /// Whether this Mac serves worktree creation.
    public let showsWorktreeCreation: Bool

    /// Memberwise initializer.
    /// - Parameters:
    ///   - header: The Mac's header facts.
    ///   - hasLoaded: Whether the projects list has loaded.
    ///   - rows: The Mac's project rows.
    ///   - showsPresets: Whether the Mac serves presets.
    ///   - presets: The Mac's presets.
    ///   - showsActions: Whether the Mac serves project actions.
    ///   - showsWorktreeCreation: Whether the Mac serves worktree creation.
    public init(
        header: SupermuxProjectsMacHeader,
        hasLoaded: Bool,
        rows: [SupermuxProjectRowSnapshot],
        showsPresets: Bool = false,
        presets: [SupermuxTerminalPresetDTO] = [],
        showsActions: Bool = false,
        showsWorktreeCreation: Bool = false
    ) {
        self.header = header
        self.hasLoaded = hasLoaded
        self.rows = rows
        self.showsPresets = showsPresets
        self.presets = presets
        self.showsActions = showsActions
        self.showsWorktreeCreation = showsWorktreeCreation
    }

    /// Whether the group has something to show: loaded, with projects.
    public var isDisplayed: Bool { hasLoaded && !rows.isEmpty }
}
