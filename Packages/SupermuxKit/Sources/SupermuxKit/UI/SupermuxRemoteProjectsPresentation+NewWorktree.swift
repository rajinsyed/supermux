public import Foundation

/// The project a New Worktree sheet is opened for: every Mac that has it, and
/// the connected Macs that could set it up.
public struct SupermuxNewWorktreeContext: Sendable {
    /// The unified project (its locations become the picker's create rows).
    public let project: SupermuxUnifiedProject
    /// Macs lacking the project ("Set Up on <Mac>…" rows).
    public let setUpTargets: [SupermuxProjectSetupDestination]

    /// Creates the context.
    public init(project: SupermuxUnifiedProject, setUpTargets: [SupermuxProjectSetupDestination]) {
        self.project = project
        self.setUpTargets = setUpTargets
    }
}

/// Builds the device-aware New Worktree sheet from the Projects section's
/// other-Mac presentation. The sidebar and the app's E2E socket drivers both
/// go through here, so a driver sees exactly the rows and default a click does.
extension SupermuxRemoteProjectsPresentation {
    /// The context of a project that has a copy on this Mac.
    public func newWorktreeContext(forLocal project: SupermuxProject) -> SupermuxNewWorktreeContext {
        if let extras = extrasByLocalProjectID[project.id] {
            return SupermuxNewWorktreeContext(project: extras.project, setUpTargets: extras.setUpTargets)
        }
        let unified = SupermuxUnifiedProject(
            id: project.id,
            name: project.name,
            colorHex: project.colorHex,
            iconSymbol: project.iconSymbol,
            gitRemoteIdentity: nil,
            locations: [SupermuxProjectLocation(place: .thisMac, projectID: project.id, rootPath: project.rootPath)]
        )
        return SupermuxNewWorktreeContext(project: unified, setUpTargets: [])
    }

    /// The context of a project that exists only on other Macs.
    public func newWorktreeContext(forRemote row: SupermuxRemoteProjectRow) -> SupermuxNewWorktreeContext {
        SupermuxNewWorktreeContext(project: row.project, setUpTargets: row.setUpTargets)
    }

    /// The sheet model for `context`: picker rows with live link states, the
    /// default Mac (an explicit choice, else the last Mac any worktree was
    /// created on when it can create here, else the first Mac that can), and
    /// targets for each copy.
    /// - Parameters:
    ///   - context: The project and its set-up targets.
    ///   - preferredDeviceKey: A Mac chosen from the row menu, if any.
    ///   - localTarget: Builds this Mac's target (only called when selected).
    ///   - onSetUp: Hands a "Set Up on <Mac>…" row to the setup sheet.
    @MainActor
    public func newWorktreeSheetModel(
        context: SupermuxNewWorktreeContext,
        preferredDeviceKey: String?,
        localTarget: @escaping @MainActor () -> (any SupermuxWorktreeCreationTarget)?,
        onSetUp: @escaping @MainActor (SupermuxProjectSetupDestination) -> Void
    ) -> SupermuxNewWorktreeSheetModel {
        let entries = SupermuxWorktreeDevicePlanner.entries(
            for: context.project,
            availability: deviceAvailability(),
            setUpTargets: context.setUpTargets
        )
        let initial = SupermuxWorktreeDevicePlanner.defaultEntryID(
            in: entries,
            preferredDeviceKey: preferredDeviceKey,
            lastUsedDeviceKey: lastWorktreeDevices.deviceKey()
        )
        let makeRemote = actions.makeWorktreeTarget
        return SupermuxNewWorktreeSheetModel(
            projectID: context.project.id,
            entries: entries,
            initialEntryID: initial,
            makeTarget: { location in location.isThisMac ? localTarget() : makeRemote(location) },
            lastDevices: lastWorktreeDevices,
            availability: deviceAvailability,
            onSetUp: onSetUp
        )
    }
}
