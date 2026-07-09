import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileUI
import Testing

/// Pure-value projections behind the changes/diff screens: wire buckets onto
/// row snapshots (filename emphasis, directory prefix, status letter), diff
/// text onto classified lines (add/remove/hunk/meta tinting), and the
/// capability gate for the workspace-tools toolbar entry (UI-02 for this
/// mount: hidden without `supermux.changes.v1`).
@Suite struct SupermuxChangesProjectionTests {
    // MARK: Changed-file row snapshots

    @Test func projectsWireFilesOntoRowsPreservingOrder() {
        let rows = SupermuxChangedFileRowSnapshot.rows(
            from: [
                SupermuxChangedFileDTO(path: "src/app/Main.swift", kind: "modified"),
                SupermuxChangedFileDTO(path: "README.md", kind: "added"),
                SupermuxChangedFileDTO(
                    path: "Sources/New.swift",
                    oldPath: "Sources/Old.swift",
                    kind: "renamed"
                ),
            ],
            area: .staged
        )
        #expect(rows.count == 3)
        #expect(rows[0].id == "staged|src/app/Main.swift")
        #expect(rows[0].fileName == "Main.swift")
        #expect(rows[0].directory == "src/app")
        #expect(rows[0].kindBadge == "M")
        #expect(rows[0].diffIsStaged)
        // Root-level files carry no directory line.
        #expect(rows[1].fileName == "README.md")
        #expect(rows[1].directory == nil)
        #expect(rows[1].kindBadge == "A")
        #expect(rows[2].oldPath == "Sources/Old.swift")
        #expect(rows[2].kindBadge == "R")
    }

    @Test func missingBucketAndUnknownKindDegradeGracefully() {
        #expect(SupermuxChangedFileRowSnapshot.rows(from: nil, area: .unstaged).isEmpty)
        let row = SupermuxChangedFileRowSnapshot(area: .untracked, path: "notes.md", kind: "future_kind")
        #expect(row.kindBadge == "•")
        #expect(!row.diffIsStaged)
        // The same path in two areas keeps distinct identities.
        let staged = SupermuxChangedFileRowSnapshot(area: .staged, path: "notes.md")
        #expect(row.id != staged.id)
    }

    // MARK: Diff line classification

    @Test func classifiesUnifiedDiffLines() {
        let diff = """
        diff --git a/src/app.swift b/src/app.swift
        index 1111111..2222222 100644
        --- a/src/app.swift
        +++ b/src/app.swift
        @@ -1,2 +1,2 @@
         context line
        -removed line
        +added line
        """
        let lines = SupermuxDiffLine.lines(from: diff)
        #expect(lines.map(\.kind) == [
            .meta, .meta, .meta, .meta, .hunk, .context, .removal, .addition,
        ])
        #expect(lines.map(\.id) == Array(0..<8))
        #expect(lines[7].text == "+added line")
    }

    @Test func dropsOnlyTheTrailingNewlineArtifact() {
        let lines = SupermuxDiffLine.lines(from: "+one\n\n+two\n")
        #expect(lines.map(\.text) == ["+one", "", "+two"])
        #expect(lines[1].kind == .context)
        #expect(SupermuxDiffLine.lines(from: "").isEmpty)
    }

    // MARK: Workspace-tools capability gate

    @Test func changesEntryRequiresTheChangesCapability() {
        #expect(!SupermuxWorkspaceTools.showsChangesEntry(hostCapabilities: nil))
        #expect(!SupermuxWorkspaceTools.showsChangesEntry(hostCapabilities: []))
        #expect(!SupermuxWorkspaceTools.showsChangesEntry(
            hostCapabilities: ["supermux.projects.v1", "workspace.groups.v1"]
        ))
        #expect(SupermuxWorkspaceTools.showsChangesEntry(
            hostCapabilities: ["supermux.changes.v1"]
        ))
    }
}
