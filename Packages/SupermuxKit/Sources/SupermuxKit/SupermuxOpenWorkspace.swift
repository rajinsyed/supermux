public import Foundation

/// An immutable snapshot of a live cmux workspace, used to render the
/// workspaces that belong to a project nested under it in the sidebar.
///
/// The host app (which owns the real `TabManager`) builds these from its open
/// workspaces and hands them to ``SupermuxProjectsSectionView``; the package
/// matches each to a project by directory (``SupermuxProjectMatcher``) and
/// renders it as a child row. Selecting or closing a row calls back into the
/// host — the package never touches app types.
public struct SupermuxOpenWorkspace: Identifiable, Hashable, Sendable {
    /// The cmux workspace identifier.
    public let id: UUID
    /// Display title (the workspace's custom title or process title).
    public let title: String
    /// Absolute working directory (normalized by the host).
    public let directory: String
    /// Whether this workspace is the currently selected one.
    public let isSelected: Bool
    /// The workspace's git branch, when known, for a subtitle.
    public let branch: String?

    /// Creates a snapshot.
    /// - Parameters:
    ///   - id: The cmux workspace identifier.
    ///   - title: Display title.
    ///   - directory: Absolute working directory.
    ///   - isSelected: Whether it is the active workspace.
    ///   - branch: Current git branch, if known.
    public init(id: UUID, title: String, directory: String, isSelected: Bool, branch: String? = nil) {
        self.id = id
        self.title = title
        self.directory = directory
        self.isSelected = isSelected
        self.branch = branch
    }
}
