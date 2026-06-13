import Foundation

/// A single changed file inside a git repository, as reported by
/// `git status --porcelain=v2`.
public struct SupermuxGitFileChange: Identifiable, Hashable, Sendable {
    /// The kind of change git reported for the file.
    public enum Kind: String, Sendable, Hashable {
        /// The file's contents changed.
        case modified
        /// The file was newly added.
        case added
        /// The file was deleted.
        case deleted
        /// The file was renamed; ``SupermuxGitFileChange/oldPath`` holds the source.
        case renamed
        /// The file was copied; ``SupermuxGitFileChange/oldPath`` holds the source.
        case copied
        /// The file is not tracked by git.
        case untracked
        /// The file has unresolved merge conflicts.
        case conflicted
        /// The file's type changed (e.g. regular file to symlink).
        case typeChanged
    }

    /// Repo-relative path of the (new) file.
    public let path: String
    /// Repo-relative source path for renames and copies, otherwise `nil`.
    public let oldPath: String?
    /// The kind of change.
    public let kind: Kind

    /// Stable identity within one snapshot: the repo-relative path.
    public var id: String { path }

    /// Creates a file change.
    /// - Parameters:
    ///   - path: Repo-relative path of the (new) file.
    ///   - oldPath: Source path for renames/copies, otherwise `nil`.
    ///   - kind: The kind of change.
    public init(path: String, oldPath: String?, kind: Kind) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
    }

    /// The last path component, for compact display.
    public var fileName: String {
        (path as NSString).lastPathComponent
    }

    /// The path minus ``fileName``, or `nil` for files at the repo root.
    public var directory: String? {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }
}

/// An immutable snapshot of a repository's working-tree status.
public struct SupermuxGitStatusSnapshot: Sendable, Hashable {
    /// Whether the inspected directory is a git repository.
    public var isRepository: Bool
    /// Current branch name, or `nil` when detached or not a repository.
    public var branch: String?
    /// Upstream branch (e.g. `origin/main`), or `nil` when none is set.
    public var upstreamBranch: String?
    /// Commits ahead of the upstream.
    public var ahead: Int
    /// Commits behind the upstream.
    public var behind: Int
    /// Changes staged in the index.
    public var staged: [SupermuxGitFileChange]
    /// Tracked-file changes in the working tree that are not staged.
    public var unstaged: [SupermuxGitFileChange]
    /// Files git does not track yet.
    public var untracked: [SupermuxGitFileChange]

    /// Creates a snapshot.
    /// - Parameters:
    ///   - isRepository: Whether the directory is a git repository.
    ///   - branch: Current branch name, or `nil` when detached.
    ///   - upstreamBranch: Upstream branch, or `nil` when none is set.
    ///   - ahead: Commits ahead of the upstream.
    ///   - behind: Commits behind the upstream.
    ///   - staged: Changes staged in the index.
    ///   - unstaged: Unstaged tracked-file changes.
    ///   - untracked: Untracked files.
    public init(
        isRepository: Bool,
        branch: String?,
        upstreamBranch: String?,
        ahead: Int,
        behind: Int,
        staged: [SupermuxGitFileChange],
        unstaged: [SupermuxGitFileChange],
        untracked: [SupermuxGitFileChange]
    ) {
        self.isRepository = isRepository
        self.branch = branch
        self.upstreamBranch = upstreamBranch
        self.ahead = ahead
        self.behind = behind
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
    }

    /// The snapshot used for directories that are not git repositories.
    public static let notARepository = SupermuxGitStatusSnapshot(
        isRepository: false,
        branch: nil,
        upstreamBranch: nil,
        ahead: 0,
        behind: 0,
        staged: [],
        unstaged: [],
        untracked: []
    )

    /// Total number of staged, unstaged, and untracked changes.
    public var totalChangeCount: Int {
        staged.count + unstaged.count + untracked.count
    }
}

/// Parses the output of `git status --porcelain=v2 --branch` into a
/// ``SupermuxGitStatusSnapshot``.
///
/// Malformed lines are skipped rather than treated as errors, so partially
/// unexpected output still yields a usable snapshot.
public struct SupermuxGitStatusParser: Sendable {
    /// Creates a parser.
    public init() {}

    /// Parses `git status --porcelain=v2 --branch` stdout into a snapshot.
    ///
    /// The returned snapshot always has `isRepository == true`; callers decide
    /// separately whether git ran successfully.
    /// - Parameter output: Raw stdout from git.
    public func parse(_ output: String) -> SupermuxGitStatusSnapshot {
        var state = ParseState()
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("# ") {
                parseHeader(line, into: &state)
            } else if line.hasPrefix("1 ") {
                parseOrdinaryEntry(line, into: &state)
            } else if line.hasPrefix("2 ") {
                parseRenameEntry(line, into: &state)
            } else if line.hasPrefix("u ") {
                parseUnmergedEntry(line, into: &state)
            } else if line.hasPrefix("? ") {
                state.untracked.append(SupermuxGitFileChange(
                    path: String(line.dropFirst(2)),
                    oldPath: nil,
                    kind: .untracked
                ))
            }
            // "! " (ignored) and unrecognized lines are skipped.
        }
        return SupermuxGitStatusSnapshot(
            isRepository: true,
            branch: state.branch,
            upstreamBranch: state.upstreamBranch,
            ahead: state.ahead,
            behind: state.behind,
            staged: state.staged,
            unstaged: state.unstaged,
            untracked: state.untracked
        )
    }

    // MARK: - Internals

    private struct ParseState {
        var branch: String?
        var upstreamBranch: String?
        var ahead = 0
        var behind = 0
        var staged: [SupermuxGitFileChange] = []
        var unstaged: [SupermuxGitFileChange] = []
        var untracked: [SupermuxGitFileChange] = []
    }

    private func parseHeader(_ line: String, into state: inout ParseState) {
        if line.hasPrefix("# branch.head ") {
            let name = String(line.dropFirst("# branch.head ".count))
            state.branch = name == "(detached)" ? nil : name
        } else if line.hasPrefix("# branch.upstream ") {
            state.upstreamBranch = String(line.dropFirst("# branch.upstream ".count))
        } else if line.hasPrefix("# branch.ab ") {
            for token in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                if token.hasPrefix("+"), let value = Int(token.dropFirst()) {
                    state.ahead = value
                } else if token.hasPrefix("-"), let value = Int(token.dropFirst()) {
                    state.behind = value
                }
            }
        }
    }

    /// Parses `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`.
    private func parseOrdinaryEntry(_ line: String, into state: inout ParseState) {
        let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9 else { return }
        let path = String(fields[8])
        guard !path.isEmpty else { return }
        appendChanges(statusPair: fields[1], path: path, oldPath: nil, into: &state)
    }

    /// Parses `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <Xscore> <path>\t<origPath>`.
    private func parseRenameEntry(_ line: String, into state: inout ParseState) {
        let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
        guard fields.count == 10 else { return }
        let pathField = fields[9]
        guard let tab = pathField.firstIndex(of: "\t") else { return }
        let newPath = String(pathField[..<tab])
        let origPath = String(pathField[pathField.index(after: tab)...])
        guard !newPath.isEmpty else { return }
        appendChanges(
            statusPair: fields[1],
            path: newPath,
            oldPath: origPath.isEmpty ? nil : origPath,
            into: &state
        )
    }

    /// Parses `u <XY> ...`, pragmatically taking the last whitespace field as
    /// the path.
    private func parseUnmergedEntry(_ line: String, into state: inout ParseState) {
        // Porcelain v2 unmerged: `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`
        // — 10 space-separated fields then the path, which may itself contain
        // spaces. Split with maxSplits so the path keeps its spaces (taking the
        // last token would truncate "my file.txt" to "file.txt").
        let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard fields.count == 11, !fields[10].isEmpty else { return }
        state.unstaged.append(SupermuxGitFileChange(
            path: String(fields[10]),
            oldPath: nil,
            kind: .conflicted
        ))
    }

    /// Appends staged/unstaged changes from a two-character `XY` status pair.
    private func appendChanges(
        statusPair: Substring,
        path: String,
        oldPath: String?,
        into state: inout ParseState
    ) {
        guard statusPair.count == 2,
              let index = statusPair.first,
              let worktree = statusPair.last else { return }
        if let kind = changeKind(for: index) {
            state.staged.append(SupermuxGitFileChange(path: path, oldPath: oldPath, kind: kind))
        }
        if let kind = changeKind(for: worktree) {
            state.unstaged.append(SupermuxGitFileChange(path: path, oldPath: oldPath, kind: kind))
        }
    }

    /// Maps a porcelain v2 status letter to a change kind; `.` and unknown
    /// letters map to `nil`.
    private func changeKind(for letter: Character) -> SupermuxGitFileChange.Kind? {
        switch letter {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        default: return nil
        }
    }
}
