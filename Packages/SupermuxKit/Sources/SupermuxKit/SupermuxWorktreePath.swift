import Foundation

/// Path normalization for worktree bookkeeping.
///
/// ``SupermuxGitWorktreeService`` compares configured project paths against
/// `git worktree list` output, so every compared path must be reduced to one
/// canonical, symlink-resolved form.
///
/// Helper landscape (the divergent semantics are intentional):
/// - ``normalized(_:)``: lexical — `standardizingPath` + trailing-slash trim
///   (tilde expansion comes along via `standardizingPath`).
/// - ``canonical(_:)``: deepest-existing-prefix symlink resolution, with the
///   missing tail re-appended.
/// - `SupermuxProjectMatcher.normalizedDirectory`: explicit tilde expansion +
///   the same lexical core as ``normalized(_:)``.
/// - `SupermuxProjectMatcher.resolvedDirectory`: `resolvingSymlinksInPath`,
///   which resolves *nothing* once any component is missing; never call it on
///   remote-mirror paths (per-component stats block on the automounter).
/// - The matcher's resolution cache is bounded to registered project paths.
enum SupermuxWorktreePath {
    /// `standardizingPath` with any trailing slash removed.
    static func normalized(_ path: String) -> String {
        trimTrailingSlash((path as NSString).standardizingPath)
    }

    /// `path` without its trailing slash (the bare root `/` keeps its).
    static func trimTrailingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Symlink-resolved form of `path`, comparable against `git worktree list`
    /// output (git prints realpaths, so a project registered via a symlinked
    /// root would otherwise never match its own worktrees).
    ///
    /// `resolvingSymlinksInPath` resolves nothing — intermediate links
    /// included — once any component is missing, so the deepest existing
    /// prefix is resolved and the missing tail re-appended. That keeps
    /// not-yet-created worktree paths and deleted checkouts in the same
    /// canonical form as their live siblings.
    static func canonical(_ path: String) -> String {
        let standardized = normalized(path)
        var existing = standardized
        var missingTail: [String] = []
        while existing.count > 1, !FileManager.default.fileExists(atPath: existing) {
            missingTail.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var resolved = (existing as NSString).resolvingSymlinksInPath
        for component in missingTail.reversed() {
            resolved = (resolved as NSString).appendingPathComponent(component)
        }
        return normalized(resolved)
    }

    /// The canonical worktrees container for a project, derived from the
    /// already-canonicalized root rather than the raw `worktreesDirPath` —
    /// resolving the not-yet-existing container itself would leave any
    /// symlinked ancestors unresolved and break the root-prefix checks.
    static func worktreesDir(canonicalRoot: String, project: SupermuxProject) -> String {
        canonical((canonicalRoot as NSString).appendingPathComponent(project.worktreesDirName))
    }

    /// The *lexical* worktrees container: the configured name appended to the
    /// canonical root with `..`/`.` collapsed but symlinks left unresolved.
    /// LEXICAL on purpose — the root-prefix escape guard fed by this rejects
    /// only `..` traversal (a corrupt/hand-edited `worktreesDirName` like
    /// `".."` would resolve to the parent directory and let worktrees, and
    /// deletions, escape into sibling repositories), while a container that is
    /// itself a symlink pointing outside the root (heavy checkouts kept on
    /// another volume) is legitimate and must not trip it.
    static func lexicalWorktreesDir(canonicalRoot: String, project: SupermuxProject) -> String {
        normalized((canonicalRoot as NSString).appendingPathComponent(project.worktreesDirName))
    }
}
