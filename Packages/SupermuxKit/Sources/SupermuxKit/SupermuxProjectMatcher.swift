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

    private static func normalize(_ path: String) -> String {
        let expanded = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        return expanded.count > 1 && expanded.hasSuffix("/") ? String(expanded.dropLast()) : expanded
    }
}
