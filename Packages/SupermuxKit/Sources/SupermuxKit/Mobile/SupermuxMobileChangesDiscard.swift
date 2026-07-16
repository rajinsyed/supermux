import Foundation

/// Re-validates a mobile `changes.discard {paths}` request against a fresh
/// git status snapshot (the mac-side re-validation architecture §7 requires
/// regardless of the phone's confirmation dialog).
///
/// Discarding is destructive, so resolution is all-or-nothing: every
/// requested path must map to a CURRENT change or the whole request is
/// rejected with the unknown paths and nothing is mutated. Each resolved
/// change carries the kind the shared ``SupermuxGitChangesService/discard``
/// path keys its behavior on — untracked files are deleted, tracked files
/// restore HEAD/index content — exactly like the desktop panel rows.
public enum SupermuxMobileChangesDiscard {
    /// The outcome of re-validating a discard request.
    public enum Resolution: Equatable, Sendable {
        /// Every path resolved; discard these changes in order.
        case changes([SupermuxGitFileChange])
        /// These requested paths are not current changes; discard nothing.
        case unknownPaths([String])
    }

    /// Maps requested repo-relative paths onto the snapshot's changes.
    ///
    /// Duplicate request paths resolve once (first occurrence order). When a
    /// path appears in more than one section, the untracked entry wins over
    /// unstaged over staged, so a discard always removes what is on disk
    /// rather than no-op checking out an identical index copy.
    /// - Parameters:
    ///   - paths: Requested repo-relative paths.
    ///   - snapshot: A FRESH status snapshot (mac-side re-validation).
    /// - Returns: The resolved changes, or every path that failed to resolve.
    public static func resolve(
        paths: [String],
        in snapshot: SupermuxGitStatusSnapshot
    ) -> Resolution {
        var changesByPath: [String: SupermuxGitFileChange] = [:]
        // Later sections override earlier ones: staged < unstaged < untracked.
        for change in snapshot.staged + snapshot.unstaged + snapshot.untracked {
            changesByPath[change.path] = change
        }
        var seen: Set<String> = []
        var resolved: [SupermuxGitFileChange] = []
        var unknown: [String] = []
        for path in paths where seen.insert(path).inserted {
            if let change = changesByPath[path] {
                resolved.append(change)
            } else {
                unknown.append(path)
            }
        }
        guard unknown.isEmpty else { return .unknownPaths(unknown) }
        return .changes(resolved)
    }
}
