import Testing

import SupermuxKit

/// Unit tests for `SupermuxGitStatusParser` against inline fixtures of
/// `git status --porcelain=v2 -z --branch` output: NUL-terminated records for
/// branch headers, ordinary, rename, and unmerged entries, untracked/ignored
/// paths, and the derived properties on `SupermuxGitFileChange` and
/// `SupermuxGitStatusSnapshot`. In `-z` mode paths are printed verbatim (no
/// C-quoting) and a rename's source path is the record after the rename entry.
struct SupermuxGitStatusParserTests {
    private let parser = SupermuxGitStatusParser()

    /// Joins porcelain-v2 records the way `-z` output arrives: NUL-terminated.
    private func zJoined(_ records: [String]) -> String {
        records.map { $0 + "\u{0}" }.joined()
    }

    // MARK: - Branch headers

    @Test func parsesBranchUpstreamAndAheadBehindHeaders() {
        let output = zJoined([
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
        ])
        let snapshot = parser.parse(output)
        #expect(snapshot.isRepository)
        #expect(snapshot.branch == "main")
        #expect(snapshot.upstreamBranch == "origin/main")
        #expect(snapshot.ahead == 2)
        #expect(snapshot.behind == 1)
    }

    @Test func detachedHeadYieldsNilBranch() {
        let snapshot = parser.parse("# branch.head (detached)\u{0}")
        #expect(snapshot.isRepository)
        #expect(snapshot.branch == nil)
        #expect(snapshot.upstreamBranch == nil)
    }

    @Test func showStashHeaderSetsStashEntryCount() {
        // `--show-stash` emits `# stash <count>` only when entries exist.
        let withStash = parser.parse(zJoined(["# branch.head main", "# stash 3"]))
        #expect(withStash.stashEntryCount == 3)

        let noStash = parser.parse("# branch.head main\u{0}")
        #expect(noStash.stashEntryCount == 0)
    }

    // MARK: - Ordinary entries (1 ...)

    @Test func stagedModifiedEntryLandsInStagedOnly() {
        let snapshot = parser.parse("1 M. N... 100644 100644 100644 abc def file.txt\u{0}")
        #expect(snapshot.staged == [
            SupermuxGitFileChange(path: "file.txt", oldPath: nil, kind: .modified)
        ])
        #expect(snapshot.unstaged.isEmpty)
        #expect(snapshot.untracked.isEmpty)
    }

    @Test func unstagedModifiedEntryLandsInUnstagedOnly() {
        let snapshot = parser.parse("1 .M N... 100644 100644 100644 abc def file.txt\u{0}")
        #expect(snapshot.unstaged == [
            SupermuxGitFileChange(path: "file.txt", oldPath: nil, kind: .modified)
        ])
        #expect(snapshot.staged.isEmpty)
        #expect(snapshot.untracked.isEmpty)
    }

    @Test func entryModifiedInIndexAndWorktreeLandsInBothLists() {
        let snapshot = parser.parse("1 MM N... 100644 100644 100644 abc def file.txt\u{0}")
        let expected = SupermuxGitFileChange(path: "file.txt", oldPath: nil, kind: .modified)
        #expect(snapshot.staged == [expected])
        #expect(snapshot.unstaged == [expected])
    }

    @Test func stagedAddedEntryHasAddedKind() {
        let snapshot = parser.parse("1 A. N... 000000 100644 100644 000 abc new.txt\u{0}")
        #expect(snapshot.staged == [
            SupermuxGitFileChange(path: "new.txt", oldPath: nil, kind: .added)
        ])
        #expect(snapshot.unstaged.isEmpty)
    }

    @Test func unstagedDeletedEntryHasDeletedKind() {
        let snapshot = parser.parse("1 .D N... 100644 100644 000000 abc def gone.txt\u{0}")
        #expect(snapshot.unstaged == [
            SupermuxGitFileChange(path: "gone.txt", oldPath: nil, kind: .deleted)
        ])
        #expect(snapshot.staged.isEmpty)
    }

    @Test func unstagedTypeChangedEntryHasTypeChangedKind() {
        let snapshot = parser.parse("1 .T N... 100644 100644 120000 abc def link.txt\u{0}")
        #expect(snapshot.unstaged == [
            SupermuxGitFileChange(path: "link.txt", oldPath: nil, kind: .typeChanged)
        ])
        #expect(snapshot.staged.isEmpty)
    }

    // MARK: - Rename entries (2 ...)

    /// In `-z` mode the rename record carries the new path and the *next*
    /// NUL-separated record is the original path (no tab separator).
    @Test func stagedRenameCapturesNewAndOldPaths() {
        let snapshot = parser.parse(zJoined([
            "2 R. N... 100644 100644 100644 abc def R100 new/name.txt",
            "old/name.txt",
        ]))
        #expect(snapshot.staged == [
            SupermuxGitFileChange(path: "new/name.txt", oldPath: "old/name.txt", kind: .renamed)
        ])
        #expect(snapshot.unstaged.isEmpty)
        #expect(snapshot.untracked.isEmpty)
    }

    /// The record after a rename is its source path even when it looks like
    /// another entry type (e.g. a file literally named like a header), and the
    /// entry after the source parses independently.
    @Test func renameSourceRecordDoesNotSwallowFollowingEntry() {
        let snapshot = parser.parse(zJoined([
            "2 R. N... 100644 100644 100644 abc def R100 renamed.txt",
            "original.txt",
            "? extra.txt",
        ]))
        #expect(snapshot.staged == [
            SupermuxGitFileChange(path: "renamed.txt", oldPath: "original.txt", kind: .renamed)
        ])
        #expect(snapshot.untracked == [
            SupermuxGitFileChange(path: "extra.txt", oldPath: nil, kind: .untracked)
        ])
    }

    /// Regression: a malformed `2` record (too few fields) must be skipped in
    /// isolation. It must not consume the following record as its source path,
    /// which previously dropped the next valid entry from the snapshot.
    @Test func malformedRenameRecordDoesNotSwallowFollowingEntry() {
        let snapshot = parser.parse(zJoined([
            "2 R. incomplete",
            "1 .M N... 100644 100644 100644 abc def survivor.txt",
            "? extra.txt",
        ]))
        #expect(snapshot.staged.isEmpty)
        #expect(snapshot.unstaged == [
            SupermuxGitFileChange(path: "survivor.txt", oldPath: nil, kind: .modified)
        ])
        #expect(snapshot.untracked == [
            SupermuxGitFileChange(path: "extra.txt", oldPath: nil, kind: .untracked)
        ])
    }

    /// A rename record with the right field count but an empty new path is
    /// also malformed and must not consume the following record.
    @Test func renameRecordWithEmptyPathDoesNotSwallowFollowingEntry() {
        let snapshot = parser.parse(zJoined([
            "2 R. N... 100644 100644 100644 abc def R100 ",
            "1 M. N... 100644 100644 100644 abc def staged.txt",
        ]))
        #expect(snapshot.staged == [
            SupermuxGitFileChange(path: "staged.txt", oldPath: nil, kind: .modified)
        ])
        #expect(snapshot.unstaged.isEmpty)
    }

    // MARK: - Untracked and ignored entries

    @Test func untrackedEntryIsListedAndIgnoredEntryIsSkipped() {
        let output = zJoined([
            "? foo/bar.txt",
            "! junk.log",
        ])
        let snapshot = parser.parse(output)
        #expect(snapshot.untracked == [
            SupermuxGitFileChange(path: "foo/bar.txt", oldPath: nil, kind: .untracked)
        ])
        #expect(snapshot.staged.isEmpty)
        #expect(snapshot.unstaged.isEmpty)
        #expect(snapshot.totalChangeCount == 1)
    }

    /// `-z` prints paths verbatim: a non-ASCII filename must arrive intact,
    /// never as a C-quoted escape string (`"r\303\251sum\303\251.txt"`).
    @Test func nonASCIIPathIsPreservedVerbatim() {
        let snapshot = parser.parse("? résumé.txt\u{0}")
        #expect(snapshot.untracked == [
            SupermuxGitFileChange(path: "résumé.txt", oldPath: nil, kind: .untracked)
        ])
    }

    /// NUL termination (not newline) delimits records, so a path containing a
    /// newline survives as one entry.
    @Test func pathContainingNewlineStaysOneRecord() {
        let snapshot = parser.parse("? weird\nname.txt\u{0}? plain.txt\u{0}")
        #expect(snapshot.untracked == [
            SupermuxGitFileChange(path: "weird\nname.txt", oldPath: nil, kind: .untracked),
            SupermuxGitFileChange(path: "plain.txt", oldPath: nil, kind: .untracked),
        ])
    }

    // MARK: - Unmerged entries (u ...)

    @Test func unmergedEntryIsUnstagedConflicted() {
        let snapshot = parser.parse(
            "u UU N... 100644 100644 100644 100644 abc def ghi conflicted.txt\u{0}"
        )
        #expect(snapshot.unstaged == [
            SupermuxGitFileChange(path: "conflicted.txt", oldPath: nil, kind: .conflicted)
        ])
        #expect(snapshot.staged.isEmpty)
        #expect(snapshot.untracked.isEmpty)
    }

    /// Regression: a porcelain-v2 unmerged record whose path contains spaces was
    /// truncated to its last whitespace token (e.g. "file.txt" instead of
    /// "my conflicted file.txt"). The path must be preserved exactly, with all
    /// interior spaces intact.
    @Test func unmergedEntryWithSpacesInPathPreservesFullPath() {
        let snapshot = parser.parse(
            "u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 my conflicted file.txt\u{0}"
        )
        #expect(snapshot.unstaged == [
            SupermuxGitFileChange(
                path: "my conflicted file.txt", oldPath: nil, kind: .conflicted
            )
        ])
        #expect(snapshot.unstaged.count == 1)
        #expect(snapshot.unstaged.first?.kind == .conflicted)
        #expect(snapshot.unstaged.first?.path == "my conflicted file.txt")
        #expect(snapshot.staged.isEmpty)
        #expect(snapshot.untracked.isEmpty)
    }

    /// A space-free unmerged path must still parse into a single conflicted
    /// unstaged change (guards against an over-eager fix that breaks the simple
    /// case).
    @Test func unmergedEntryWithoutSpacesStillParses() {
        let snapshot = parser.parse(
            "u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 conflicted.txt\u{0}"
        )
        #expect(snapshot.unstaged.count == 1)
        #expect(snapshot.unstaged.first?.kind == .conflicted)
        #expect(snapshot.unstaged.first?.path == "conflicted.txt")
        #expect(snapshot.staged.isEmpty)
        #expect(snapshot.untracked.isEmpty)
    }

    // MARK: - Paths with spaces

    @Test func pathContainingSpacesIsPreservedExactly() {
        let snapshot = parser.parse(
            "1 .M N... 100644 100644 100644 abc def my file with spaces.txt\u{0}"
        )
        #expect(snapshot.unstaged == [
            SupermuxGitFileChange(path: "my file with spaces.txt", oldPath: nil, kind: .modified)
        ])
    }

    // MARK: - Empty input

    @Test func emptyOutputIsCleanRepository() {
        let snapshot = parser.parse("")
        #expect(snapshot.isRepository)
        #expect(snapshot.branch == nil)
        #expect(snapshot.upstreamBranch == nil)
        #expect(snapshot.ahead == 0)
        #expect(snapshot.behind == 0)
        #expect(snapshot.staged.isEmpty)
        #expect(snapshot.unstaged.isEmpty)
        #expect(snapshot.untracked.isEmpty)
        #expect(snapshot.totalChangeCount == 0)
    }

    // MARK: - Combined fixture

    @Test func parsesFullStatusOutputAcrossAllSections() {
        let output = zJoined([
            "# branch.head feature/changes",
            "# branch.upstream origin/feature/changes",
            "# branch.ab +3 -0",
            "1 M. N... 100644 100644 100644 abc def staged.txt",
            "1 .M N... 100644 100644 100644 abc def unstaged.txt",
            "2 R. N... 100644 100644 100644 abc def R100 new/name.txt",
            "old/name.txt",
            "u UU N... 100644 100644 100644 100644 abc def ghi conflicted.txt",
            "? brand-new.txt",
            "! ignored.log",
        ])
        let snapshot = parser.parse(output)
        #expect(snapshot.branch == "feature/changes")
        #expect(snapshot.upstreamBranch == "origin/feature/changes")
        #expect(snapshot.ahead == 3)
        #expect(snapshot.behind == 0)
        #expect(snapshot.staged == [
            SupermuxGitFileChange(path: "staged.txt", oldPath: nil, kind: .modified),
            SupermuxGitFileChange(path: "new/name.txt", oldPath: "old/name.txt", kind: .renamed),
        ])
        #expect(snapshot.unstaged == [
            SupermuxGitFileChange(path: "unstaged.txt", oldPath: nil, kind: .modified),
            SupermuxGitFileChange(path: "conflicted.txt", oldPath: nil, kind: .conflicted),
        ])
        #expect(snapshot.untracked == [
            SupermuxGitFileChange(path: "brand-new.txt", oldPath: nil, kind: .untracked)
        ])
        #expect(snapshot.totalChangeCount == 5)
    }

    // MARK: - SupermuxGitStatusSnapshot

    @Test func totalChangeCountSumsAllThreeLists() {
        let snapshot = SupermuxGitStatusSnapshot(
            isRepository: true,
            branch: "main",
            upstreamBranch: nil,
            ahead: 0,
            behind: 0,
            staged: [
                SupermuxGitFileChange(path: "a.txt", oldPath: nil, kind: .added),
                SupermuxGitFileChange(path: "b.txt", oldPath: nil, kind: .modified),
            ],
            unstaged: [
                SupermuxGitFileChange(path: "c.txt", oldPath: nil, kind: .deleted)
            ],
            untracked: [
                SupermuxGitFileChange(path: "d.txt", oldPath: nil, kind: .untracked),
                SupermuxGitFileChange(path: "e.txt", oldPath: nil, kind: .untracked),
                SupermuxGitFileChange(path: "f.txt", oldPath: nil, kind: .untracked),
            ]
        )
        #expect(snapshot.totalChangeCount == 6)
    }

    @Test func notARepositorySnapshotIsEmpty() {
        let snapshot = SupermuxGitStatusSnapshot.notARepository
        #expect(!snapshot.isRepository)
        #expect(snapshot.branch == nil)
        #expect(snapshot.upstreamBranch == nil)
        #expect(snapshot.ahead == 0)
        #expect(snapshot.behind == 0)
        #expect(snapshot.totalChangeCount == 0)
        #expect(snapshot.stashEntryCount == 0)
        #expect(!snapshot.hasTrackedChanges)
        #expect(!snapshot.hasConflicts)
    }

    @Test func hasTrackedChangesIgnoresUntrackedFiles() {
        let untrackedOnly = parser.parse(zJoined(["# branch.head main", "? new.txt"]))
        #expect(!untrackedOnly.hasTrackedChanges)
        #expect(untrackedOnly.totalChangeCount == 1)

        let trackedEdit = parser.parse(zJoined([
            "# branch.head main",
            "1 .M N... 100644 100644 100644 0000000 0000000 edit.txt",
        ]))
        #expect(trackedEdit.hasTrackedChanges)
    }

    @Test func hasConflictsReflectsUnmergedEntries() {
        let clean = parser.parse(zJoined([
            "# branch.head main",
            "1 .M N... 100644 100644 100644 0000000 0000000 edit.txt",
        ]))
        #expect(!clean.hasConflicts)

        let conflicted = parser.parse(zJoined([
            "# branch.head main",
            "u UU N... 100644 100644 100644 100644 0 0 0 merge.txt",
        ]))
        #expect(conflicted.hasConflicts)
    }

    // MARK: - SupermuxGitFileChange derived properties

    @Test func fileNameAndDirectorySplitNestedPath() {
        let change = SupermuxGitFileChange(path: "a/b/c.txt", oldPath: nil, kind: .modified)
        #expect(change.fileName == "c.txt")
        #expect(change.directory == "a/b")
    }

    @Test func fileNameAndDirectoryAtRepositoryRoot() {
        let change = SupermuxGitFileChange(path: "root.txt", oldPath: nil, kind: .untracked)
        #expect(change.fileName == "root.txt")
        #expect(change.directory == nil)
    }

    @Test func idIsThePath() {
        let change = SupermuxGitFileChange(path: "a/b/c.txt", oldPath: nil, kind: .modified)
        #expect(change.id == "a/b/c.txt")
    }
}
