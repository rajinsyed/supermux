import Foundation
import os

/// Resolves which registered project a workspace directory belongs to.
///
/// Used by the run action (⌘G) to find the project whose `runCommands` apply
/// to the active workspace: the workspace may sit at the project root, inside
/// one of its worktrees, or anywhere below the root. The most specific match
/// wins: projects rank by the deepest registered form that actually contains
/// the directory, so nested projects resolve correctly even when the outer
/// project matches only through a symlink alias of a different length.
///
/// Registered project paths are compared in both their logical (as-written)
/// and symlink-resolved forms, so a shell that reports the physical path
/// (e.g. `/Volumes/Dev/repo` for a project registered as `~/dev/repo` through
/// a symlink) still matches. Workspace directories are never resolved — they
/// can be remote-mirror paths where per-component stat calls block on the
/// automounter, and matching runs on sidebar render paths.
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
            let forms = Self.registeredForms(of: project.rootPath)
                + Self.registeredForms(of: project.worktreesDirPath)
            // Rank by the longest form that ACTUALLY contains the directory.
            // Every matched form (across all projects) is a prefix of the same
            // path, so the longest one is the deepest owning directory; a
            // fixed form's length would mix unrelated spellings and let an
            // outer project registered through a long symlink alias outrank a
            // project nested inside it.
            let specificity = forms
                .filter { Self.isDirectory(normalized, atOrUnder: $0) }
                .map(\.count)
                .max()
            guard let specificity else { continue }
            if best == nil || specificity > best!.specificity {
                best = (project, specificity)
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
        return projectOwningWorktree(forNormalizedDirectory: Self.normalize(directory), in: projects)
    }

    /// Variant of ``projectOwningWorktree(for:in:)`` taking a directory already
    /// canonicalized by ``normalizedDirectory(_:)``, so callers that normalized
    /// the path for their own lookup (the association store's durable-link
    /// check) don't pay the NSString normalization twice per resolution.
    /// - Parameters:
    ///   - normalized: The workspace's directory, pre-normalized.
    ///   - projects: All registered projects.
    public func projectOwningWorktree(
        forNormalizedDirectory normalized: String,
        in projects: [SupermuxProject]
    ) -> SupermuxProject? {
        guard !normalized.isEmpty else { return nil }
        var best: (project: SupermuxProject, specificity: Int)?
        for project in projects {
            // Same matched-form ranking as ``project(for:in:)``: the deepest
            // worktrees-dir form that actually contains the directory wins.
            let specificity = Self.registeredForms(of: project.worktreesDirPath)
                .filter { normalized.hasPrefix($0 + "/") }
                .map(\.count)
                .max()
            guard let specificity else { continue }
            if best == nil || specificity > best!.specificity {
                best = (project, specificity)
            }
        }
        return best?.project
    }

    /// Canonicalizes a directory path so the same location always maps to the
    /// same string: tildes are expanded, `.`/`..` resolved, and a trailing slash
    /// dropped. Shared so durable directory→project links
    /// (``SupermuxDirectoryAssociationPersisting``) are keyed identically on
    /// write and read. Does NOT resolve symlinks — cheap enough for render-path
    /// lookups and safe for remote-mirror paths.
    /// - Parameter path: A directory path.
    /// - Returns: The normalized path.
    public static func normalizedDirectory(_ path: String) -> String {
        normalize(path)
    }

    /// Fully canonical form of a *local* directory: normalized like
    /// ``normalizedDirectory(_:)`` plus symlink resolution, so the logical and
    /// physical spellings of one location converge. Resolution stats every
    /// path component, so callers use this only on write/registration paths
    /// (project add, durable-link write) — never per render, and never on
    /// remote-mirror directories.
    /// - Parameter path: A local directory path.
    /// - Returns: The resolved, normalized path.
    public static func resolvedDirectory(_ path: String) -> String {
        SupermuxWorktreePath.trimTrailingSlash((normalize(path) as NSString).resolvingSymlinksInPath)
    }

    private static func isDirectory(_ directory: String, atOrUnder root: String) -> Bool {
        directory == root || directory.hasPrefix(root + "/")
    }

    /// Both canonical forms of a registered project path — logical first, then
    /// the symlink-resolved form when it differs. Resolution results are cached
    /// (the key set is bounded by registered project paths, which are local)
    /// so matching stays cheap on render paths.
    private static func registeredForms(of path: String) -> [String] {
        let normalized = normalize(path)
        let resolved = cachedResolvedForm(of: normalized)
        return resolved == normalized ? [normalized] : [normalized, resolved]
    }

    /// Symlink-resolved forms keyed by normalized project path. Entries live
    /// for the process lifetime; a symlink retargeted mid-session is not
    /// re-resolved until relaunch, which is acceptable for project roots.
    private static let resolvedForms = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    private static func cachedResolvedForm(of normalized: String) -> String {
        if let cached = resolvedForms.withLock({ $0[normalized] }) { return cached }
        let resolved = SupermuxWorktreePath.trimTrailingSlash((normalized as NSString).resolvingSymlinksInPath)
        resolvedForms.withLock { $0[normalized] = resolved }
        return resolved
    }

    /// Explicit tilde expansion + the shared lexical standardize-and-trim core
    /// (see the helper landscape on ``SupermuxWorktreePath``).
    private static func normalize(_ path: String) -> String {
        SupermuxWorktreePath.normalized((path as NSString).expandingTildeInPath)
    }
}
