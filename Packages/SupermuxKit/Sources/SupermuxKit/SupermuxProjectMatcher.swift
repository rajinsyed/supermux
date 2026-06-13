import Foundation

/// Resolves which registered project a workspace directory belongs to.
///
/// Used by the run action (⌘G) to find the project whose `runCommands` apply
/// to the active workspace: the workspace may sit at the project root, inside
/// one of its worktrees, or anywhere below the root. The most specific
/// (longest) matching root wins so nested projects resolve correctly.
public struct SupermuxProjectMatcher: Sendable {
    /// Creates a matcher. Stateless; exists for injectability.
    public init() {}

    /// Returns the project owning `directory`, or `nil` when none matches.
    /// - Parameters:
    ///   - directory: The workspace's current directory.
    ///   - projects: All registered projects.
    public func project(for directory: String?, in projects: [SupermuxProject]) -> SupermuxProject? {
        guard let directory, !directory.isEmpty else { return nil }
        let normalized = Self.normalize(directory)
        var best: (project: SupermuxProject, specificity: Int)?
        for project in projects {
            let root = Self.normalize(project.rootPath)
            let worktreesDir = Self.normalize(project.worktreesDirPath)
            let matches = normalized == root
                || normalized.hasPrefix(root + "/")
                || normalized == worktreesDir
                || normalized.hasPrefix(worktreesDir + "/")
            guard matches else { continue }
            if best == nil || root.count > best!.specificity {
                best = (project, root.count)
            }
        }
        return best?.project
    }

    /// Returns the project whose worktrees directory contains `directory`, or
    /// `nil` when none does.
    ///
    /// Unlike ``project(for:in:)`` this matches *only* a project's worktrees
    /// dir — not its root or arbitrary subdirectories. It is the durable signal
    /// for nesting a worktree workspace under its project in the sidebar (it
    /// holds even across restarts, when explicit associations are gone), while
    /// avoiding the over-capture that would swallow an unrelated workspace that
    /// merely lives somewhere inside a project's root.
    /// - Parameters:
    ///   - directory: The workspace's current directory.
    ///   - projects: All registered projects.
    public func projectOwningWorktree(for directory: String?, in projects: [SupermuxProject]) -> SupermuxProject? {
        guard let directory, !directory.isEmpty else { return nil }
        let normalized = Self.normalize(directory)
        var best: (project: SupermuxProject, specificity: Int)?
        for project in projects {
            let worktreesDir = Self.normalize(project.worktreesDirPath)
            guard normalized.hasPrefix(worktreesDir + "/") else { continue }
            if best == nil || worktreesDir.count > best!.specificity {
                best = (project, worktreesDir.count)
            }
        }
        return best?.project
    }

    /// Canonicalizes a directory path so the same location always maps to the
    /// same string: tildes are expanded, `.`/`..` resolved, and a trailing slash
    /// dropped. Shared so durable directory→project links
    /// (``SupermuxDirectoryAssociationPersisting``) are keyed identically on
    /// write and read.
    /// - Parameter path: A directory path.
    /// - Returns: The normalized path.
    public static func normalizedDirectory(_ path: String) -> String {
        normalize(path)
    }

    private static func normalize(_ path: String) -> String {
        let expanded = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        return expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
    }
}
