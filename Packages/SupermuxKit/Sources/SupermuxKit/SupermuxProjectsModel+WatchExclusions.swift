import Foundation

extension SupermuxProjectsModel {
    /// The directories a Changes watcher on `path` can skip: the worktrees
    /// container of every registered project whose root is `path`.
    ///
    /// The checkouts in there are other branches. Creating one lists the
    /// container in the root's `.git/info/exclude`, so their edits never
    /// change the root's status, yet a recursive watcher on the root would
    /// wake for every file an agent writes in any of them. Empty for every
    /// other directory (a worktree itself, a subfolder, an unregistered
    /// repository). Roots match in their symlink-resolved form, so a
    /// workspace that reached the root through a symlinked ancestor (`/tmp`,
    /// a `~/code` link to another volume) still skips it.
    /// ``SupermuxRepositoryWatcher`` drops a container that is not strictly
    /// inside `path` (a `..` name), and filters one that does not exist yet
    /// from the moment the first worktree creates it.
    /// - Parameter path: The directory the watcher is about to watch.
    /// - Returns: Absolute container paths, usually none or one.
    public func worktreeContainers(forRoot path: String) -> [String] {
        let root = SupermuxWorktreePath.canonical(path)
        return projects
            .filter { SupermuxWorktreePath.canonical($0.rootPath) == root }
            .map { SupermuxWorktreePath.lexicalWorktreesDir(canonicalRoot: root, project: $0) }
    }
}
