import Foundation

/// What supermux asks the host app to open when the user activates a project
/// or worktree.
public struct SupermuxOpenWorkspaceRequest: Sendable, Hashable {
    /// Workspace title (project name or branch name).
    public var title: String
    /// Absolute working directory for the workspace.
    public var directory: String
    /// Accent color (`#RRGGBB`) applied to the workspace tab, if any.
    public var colorHex: String?

    /// Creates a request.
    /// - Parameters:
    ///   - title: Workspace title.
    ///   - directory: Absolute working directory.
    ///   - colorHex: Optional accent color.
    public init(title: String, directory: String, colorHex: String? = nil) {
        self.title = title
        self.directory = directory
        self.colorHex = colorHex
    }
}

/// Seam through which SupermuxKit opens workspaces in the host app.
///
/// The cmux app target implements this with its `TabManager` (select an
/// existing workspace whose directory matches, otherwise create one). Keeping
/// the protocol here lets the whole projects UI live in this package without
/// depending on app-target types.
@MainActor
public protocol SupermuxWorkspaceOpening: AnyObject {
    /// Opens (or focuses) a workspace for the request.
    func openWorkspace(_ request: SupermuxOpenWorkspaceRequest)
}
