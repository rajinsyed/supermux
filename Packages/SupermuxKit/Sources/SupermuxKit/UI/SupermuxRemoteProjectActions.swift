public import Foundation
public import SupermuxMobileCore

/// The fields of a worktree create on another Mac.
public struct SupermuxRemoteWorktreeRequest: Hashable, Sendable {
    /// Workspace title; blank lets the other Mac name it from the branch.
    public var workspaceName: String
    /// Branch to create; blank lets the other Mac pick (AI or random).
    public var branchName: String
    /// Starting branch; blank uses the project's default branch.
    public var baseBranch: String

    /// Creates a request.
    public init(workspaceName: String = "", branchName: String = "", baseBranch: String = "") {
        self.workspaceName = workspaceName
        self.branchName = branchName
        self.baseBranch = baseBranch
    }
}

/// Where "Set Up on <Mac>…" registers a project copy.
public enum SupermuxProjectSetupDestination: Hashable, Sendable {
    /// This Mac (the local projects model).
    case thisMac
    /// Another Mac, over its device link.
    case device(SupermuxProjectDevice)

    /// The Mac's display name.
    public var name: String {
        switch self {
        case .thisMac: return String(localized: "supermux.devices.thisMac", defaultValue: "This Mac")
        case .device(let device): return device.name
        }
    }
}

/// Callbacks the Projects section needs for copies of projects on other
/// Macs. The host app implements them over the device link (RPC to the other
/// Mac, then opening the local mirror of whatever workspace it returns).
/// Every callback handles its own errors except the `async throws` ones,
/// whose errors the calling sheet shows inline.
public struct SupermuxRemoteProjectActions {
    /// Opens the project root on that Mac (`project.open`) and focuses the mirror.
    public var openProject: (SupermuxProjectLocation) -> Void
    /// Opens a remote worktree (`worktree.open`) and focuses the mirror.
    public var openWorktree: (SupermuxRemoteWorktree) -> Void
    /// Removes a remote worktree; the Bool also deletes its branch. Asks before
    /// forcing a dirty worktree.
    public var removeWorktree: (SupermuxRemoteWorktree, Bool) -> Void
    /// Runs a project action on that Mac (`action.run`; URL actions open here).
    public var runAction: (SupermuxProjectLocation, SupermuxProjectActionDTO) -> Void
    /// Unregisters the project on that Mac after a confirmation (`project.delete`).
    public var removeProject: (SupermuxProjectLocation, String) -> Void
    /// Loads (or refreshes) that copy's worktrees for the disclosure.
    public var loadWorktrees: (SupermuxProjectLocation) -> Void
    /// The New Worktree sheet's target for that Mac's copy (branches, AI
    /// names, Claude options, `worktree.create` / `agent.start`, then the
    /// mirror opens and is selected in this window); `nil` when unavailable.
    public var makeWorktreeTarget: @MainActor (SupermuxProjectLocation) -> (any SupermuxWorktreeCreationTarget)?
    /// Registers an existing folder as the project on a Mac.
    public var addExistingFolder: (SupermuxProjectSetupDestination, String) async throws -> Void
    /// Clones the repository into a folder on a Mac and registers it.
    public var cloneRepository: (SupermuxProjectSetupDestination, String, String) async throws -> Void
    /// "Hide Here" for a nested device mirror (by local workspace id): it
    /// keeps running on its Mac, leaves this sidebar, and auto-mirror leaves
    /// it closed until "Show Hidden Remote Workspaces".
    public var hideMirror: (UUID) -> Void

    /// Creates the bundle.
    public init(
        openProject: @escaping (SupermuxProjectLocation) -> Void,
        openWorktree: @escaping (SupermuxRemoteWorktree) -> Void,
        removeWorktree: @escaping (SupermuxRemoteWorktree, Bool) -> Void,
        runAction: @escaping (SupermuxProjectLocation, SupermuxProjectActionDTO) -> Void,
        removeProject: @escaping (SupermuxProjectLocation, String) -> Void,
        loadWorktrees: @escaping (SupermuxProjectLocation) -> Void,
        makeWorktreeTarget: @escaping @MainActor (SupermuxProjectLocation) -> (any SupermuxWorktreeCreationTarget)?,
        addExistingFolder: @escaping (SupermuxProjectSetupDestination, String) async throws -> Void,
        cloneRepository: @escaping (SupermuxProjectSetupDestination, String, String) async throws -> Void,
        hideMirror: @escaping (UUID) -> Void = { _ in }
    ) {
        self.openProject = openProject
        self.openWorktree = openWorktree
        self.removeWorktree = removeWorktree
        self.runAction = runAction
        self.removeProject = removeProject
        self.loadWorktrees = loadWorktrees
        self.makeWorktreeTarget = makeWorktreeTarget
        self.addExistingFolder = addExistingFolder
        self.cloneRepository = cloneRepository
        self.hideMirror = hideMirror
    }

    /// No-op callbacks (previews, and hosts without devices).
    public static var inert: SupermuxRemoteProjectActions {
        SupermuxRemoteProjectActions(
            openProject: { _ in },
            openWorktree: { _ in },
            removeWorktree: { _, _ in },
            runAction: { _, _ in },
            removeProject: { _, _ in },
            loadWorktrees: { _ in },
            makeWorktreeTarget: { _ in nil },
            addExistingFolder: { _, _ in },
            cloneRepository: { _, _, _ in }
        )
    }
}
