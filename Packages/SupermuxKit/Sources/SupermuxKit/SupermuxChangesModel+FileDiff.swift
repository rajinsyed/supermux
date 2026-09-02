import Foundation

/// One file's captured patch from the Changes panel, ready for a host diff
/// viewer: a unified diff limited to that file and side (index or working
/// tree), plus the context a viewer needs to title and scope it.
public struct SupermuxFileDiffPatch: Sendable, Equatable {
    /// The repository directory the patch was captured in.
    public let repoPath: String
    /// The file the patch covers.
    public let change: SupermuxGitFileChange
    /// Whether the patch is the index-vs-HEAD (staged) side.
    public let staged: Bool
    /// Unified diff text.
    public let patch: String
    /// Whether the text was cut at the service's byte cap.
    public let truncated: Bool

    /// Creates a file patch.
    /// - Parameters:
    ///   - repoPath: Repository directory the patch was captured in.
    ///   - change: The file the patch covers.
    ///   - staged: Whether this is the staged (index) side.
    ///   - patch: Unified diff text.
    ///   - truncated: Whether the text was byte-capped.
    public init(repoPath: String, change: SupermuxGitFileChange, staged: Bool, patch: String, truncated: Bool) {
        self.repoPath = repoPath
        self.change = change
        self.staged = staged
        self.patch = patch
        self.truncated = truncated
    }

    /// A viewer title: the repo-relative path, suffixed for the staged side so
    /// the two sides of one file are distinguishable in a tab strip.
    public var title: String {
        staged
            ? String(localized: "supermux.changes.fileDiff.stagedTitle", defaultValue: "\(change.path) (staged)")
            : change.path
    }
}

/// The per-file diff capture behind a click on a file row.
///
/// Split out of `SupermuxChangesModel.swift` so the core model stays focused
/// on status and working-tree mutations.
extension SupermuxChangesModel {
    /// Captures the patch for one file row so the host can show it in a diff
    /// viewer.
    ///
    /// `staged` selects the side the row was clicked in: the Staged section
    /// diffs the index against `HEAD`; the Changes and Untracked sections diff
    /// the working tree (an untracked file previews as a full addition).
    /// Renames hand both paths to git so the staged side reports the rename
    /// rather than a bare addition.
    ///
    /// A binary file or an empty diff (the status was stale — the file was
    /// reverted or committed underneath the panel) is reported through
    /// ``lastError`` and returns `nil`; the empty case also refreshes the
    /// status so the list catches up. A result whose directory was switched
    /// away mid-capture is discarded.
    /// - Parameters:
    ///   - change: The file row that was activated.
    ///   - staged: Whether the row sits in the Staged section.
    /// - Returns: The patch to present, or `nil` when there is nothing to show.
    public func fileDiffPatch(for change: SupermuxGitFileChange, staged: Bool) async -> SupermuxFileDiffPatch? {
        guard let directory else { return nil }
        let generation = directoryGeneration
        let diff = await service.fileDiff(
            repoPath: directory, path: change.path, oldPath: change.oldPath, staged: staged
        )
        guard generation == directoryGeneration else { return nil }
        if diff.isBinary {
            lastError = String(
                localized: "supermux.changes.fileDiff.binary",
                defaultValue: "“\(change.fileName)” is a binary file; there is no text diff to show."
            )
            return nil
        }
        guard let text = diff.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = String(
                localized: "supermux.changes.fileDiff.empty",
                defaultValue: "No changes to show for “\(change.fileName)”."
            )
            await refresh()
            return nil
        }
        if lastError != nil { lastError = nil }
        return SupermuxFileDiffPatch(
            repoPath: directory, change: change, staged: staged, patch: text, truncated: diff.truncated
        )
    }
}
