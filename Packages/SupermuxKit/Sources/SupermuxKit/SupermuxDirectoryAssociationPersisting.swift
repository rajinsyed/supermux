public import Foundation

/// Durable storage of "this directory was opened from this project" links,
/// keyed by a normalized directory path so they survive an app restart.
///
/// cmux assigns every restored workspace a fresh `UUID`
/// (``SupermuxWorkspaceAssociationStore`` documents why id-keyed links cannot
/// persist), but it *does* restore each workspace's `currentDirectory`. A
/// project's main workspace sits at the project root — not inside a worktrees
/// dir — so it has no structural nesting signal and would pop out to the flat
/// list on relaunch. Persisting the link by directory is the restore-stable
/// fix: the root was explicitly opened from the project, so we remember it.
///
/// ``SupermuxProjectsModel`` implements this on top of the projects file;
/// ``SupermuxWorkspaceAssociationStore`` consults it during resolution and
/// writes through it when a workspace is opened from a project.
///
/// A link is a *project-level* fact ("this directory is a known entry point for
/// this project"), so it is not cleared when an individual workspace closes —
/// only when its project is removed. That keeps a project's main workspace
/// nested even if a sidebar close is cancelled or a sibling workspace at the
/// same directory closes.
@MainActor
public protocol SupermuxDirectoryAssociationPersisting: AnyObject {
    /// Normalized directory path → owning project id, for directories that were
    /// explicitly opened from a project.
    var directoryAssociations: [String: UUID] { get }

    /// Durably records that `directory` was opened from `projectId`.
    /// - Parameters:
    ///   - directory: The opened directory (normalized by the implementer).
    ///   - projectId: The project it was launched from.
    func associateDirectory(_ directory: String, with projectId: UUID)
}
