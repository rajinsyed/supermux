public import AppKit
public import Foundation
public import SupermuxMobileCore

/// Other Macs' parts of a project that also exists on this Mac: rendered by
/// that project's normal row (device-chipped worktrees, "Open on ▸",
/// "Set Up on <Mac>…").
public struct SupermuxProjectRemoteExtras {
    /// The unified project (this Mac's copy plus the device copies).
    public let project: SupermuxUnifiedProject
    /// Unopened worktrees of the device copies (loaded lazily).
    public let worktrees: [SupermuxRemoteWorktree]
    /// Connected Macs that lack a copy ("Set Up on <Mac>…").
    public let setUpTargets: [SupermuxProjectSetupDestination]
    /// The repository URL a clone would use, if known.
    public let remoteURL: String?

    /// Creates the extras.
    public init(
        project: SupermuxUnifiedProject,
        worktrees: [SupermuxRemoteWorktree],
        setUpTargets: [SupermuxProjectSetupDestination],
        remoteURL: String?
    ) {
        self.project = project
        self.worktrees = worktrees
        self.setUpTargets = setUpTargets
        self.remoteURL = remoteURL
    }
}

/// A project that exists only on other Macs, as one sidebar row.
public struct SupermuxRemoteProjectRow: Identifiable {
    /// The unified project.
    public let project: SupermuxUnifiedProject
    /// A display-only record for the avatar (name, color, SF Symbol).
    public let avatar: SupermuxProject
    /// The project's icon image fetched from its Mac, if it has one.
    public let icon: NSImage?
    /// The copy this row acts on (its first location).
    public let location: SupermuxProjectLocation
    /// The project's actions on that Mac.
    public let actions: [SupermuxProjectActionDTO]
    /// Whether that Mac reports the project's run command as running.
    public let isRunning: Bool
    /// That copy's unopened worktrees (loaded lazily).
    public let worktrees: [SupermuxRemoteWorktree]
    /// Connected Macs (and this Mac) lacking a copy ("Set Up on <Mac>…").
    public let setUpTargets: [SupermuxProjectSetupDestination]
    /// The repository URL a clone would use, if known.
    public let remoteURL: String?

    /// Creates the row value.
    public init(
        project: SupermuxUnifiedProject,
        avatar: SupermuxProject,
        icon: NSImage?,
        location: SupermuxProjectLocation,
        actions: [SupermuxProjectActionDTO],
        isRunning: Bool,
        worktrees: [SupermuxRemoteWorktree],
        setUpTargets: [SupermuxProjectSetupDestination],
        remoteURL: String?
    ) {
        self.project = project
        self.avatar = avatar
        self.icon = icon
        self.location = location
        self.actions = actions
        self.isRunning = isRunning
        self.worktrees = worktrees
        self.setUpTargets = setUpTargets
        self.remoteURL = remoteURL
    }

    public var id: UUID { project.id }
}

/// Everything the Projects section renders about other Macs, built by the
/// host each render from its remote-projects model.
public struct SupermuxRemoteProjectsPresentation {
    /// Remote-only project rows, after the local projects.
    public var rows: [SupermuxRemoteProjectRow]
    /// Device extras for local projects that also exist on other Macs.
    public var extrasByLocalProjectID: [UUID: SupermuxProjectRemoteExtras]
    /// The host's remote callbacks.
    public var actions: SupermuxRemoteProjectActions
    /// Each known Mac's link state by machine id (the New Worktree picker's dots).
    public var deviceAvailability: [String: SupermuxWorktreeDeviceAvailability]
    /// Where the New Worktree sheet remembers the last Mac per project.
    public var lastWorktreeDevices: SupermuxWorktreeLastDeviceStore

    /// Creates a presentation.
    public init(
        rows: [SupermuxRemoteProjectRow],
        extrasByLocalProjectID: [UUID: SupermuxProjectRemoteExtras],
        actions: SupermuxRemoteProjectActions,
        deviceAvailability: [String: SupermuxWorktreeDeviceAvailability] = [:],
        lastWorktreeDevices: SupermuxWorktreeLastDeviceStore = SupermuxWorktreeLastDeviceStore()
    ) {
        self.rows = rows
        self.extrasByLocalProjectID = extrasByLocalProjectID
        self.actions = actions
        self.deviceAvailability = deviceAvailability
        self.lastWorktreeDevices = lastWorktreeDevices
    }

    /// No other Macs.
    public static var empty: SupermuxRemoteProjectsPresentation {
        SupermuxRemoteProjectsPresentation(rows: [], extrasByLocalProjectID: [:], actions: .inert)
    }
}
