import Foundation
import SupermuxClaudeHarness
import Testing
@testable import SupermuxKit

/// Diff parsing, including the `structuredPatch` shape Claude Code actually
/// emits on Edit/Write/MultiEdit results (the fixture corpus has it as `[]` for
/// a file creation, which must NOT render as an empty diff card).
struct SupermuxHarnessDiffTests {
    private func json(_ text: String) -> ClaudeJSONValue {
        try! JSONDecoder().decode(ClaudeJSONValue.self, from: Data(text.utf8))
    }

    @Test func structuredPatchBecomesNumberedHunks() {
        let result = json("""
        {"structuredPatch":[{"oldStart":10,"oldLines":3,"newStart":10,"newLines":4,
        "lines":[" context","-old line","+new line","+added line"]}]}
        """)
        let diff = SupermuxHarnessDiff.from(toolUseResult: result)
        #expect(diff != nil)
        guard let diff, let hunk = diff.hunks.first else { return }
        #expect(diff.hunks.count == 1)
        #expect(diff.additions == 2)
        #expect(diff.deletions == 1)
        #expect(hunk.lines[0].kind == .context)
        #expect(hunk.lines[0].oldNumber == 10)
        #expect(hunk.lines[0].newNumber == 10)
        // A deletion advances only the old side; an addition only the new side.
        #expect(hunk.lines[1].oldNumber == 11)
        #expect(hunk.lines[1].newNumber == nil)
        #expect(hunk.lines[2].newNumber == 11)
        #expect(hunk.lines[2].oldNumber == nil)
    }

    @Test func emptyStructuredPatchYieldsNoDiff() {
        // Verbatim from the captured Write result in the fixture corpus.
        let result = json("""
        {"type":"create","filePath":"/tmp/x.txt","content":"approved",
        "structuredPatch":[],"originalFile":null,"userModified":false}
        """)
        #expect(SupermuxHarnessDiff.from(toolUseResult: result) == nil)
    }

    @Test func missingStructuredPatchYieldsNoDiff() {
        #expect(SupermuxHarnessDiff.from(toolUseResult: json("{\"stdout\":\"ok\"}")) == nil)
        #expect(SupermuxHarnessDiff.from(toolUseResult: nil) == nil)
    }

    @Test func unifiedDiffTextParsesHunkHeaders() {
        let diff = SupermuxHarnessDiff.parse("""
        diff --git a/x.swift b/x.swift
        index abc..def 100644
        --- a/x.swift
        +++ b/x.swift
        @@ -5,3 +5,4 @@
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
        """)
        #expect(diff.hunks.count == 1)
        #expect(diff.additions == 2)
        #expect(diff.deletions == 1)
        // Metadata lines are dropped, not rendered as context.
        #expect(diff.hunks[0].lines.count == 4)
        #expect(diff.hunks[0].isSynthetic == false)
        #expect(diff.hunks[0].oldStart == 5)
    }

    @Test func headerlessDiffOpensASyntheticHunk() {
        let diff = SupermuxHarnessDiff.parse("+one\n+two\n")
        #expect(diff.hunks.count == 1)
        #expect(diff.hunks[0].isSynthetic)
        #expect(diff.additions == 2)
    }

    @Test func nonDiffTextProducesNoHunks() {
        #expect(SupermuxHarnessDiff.parse("just some prose\n").hunks.isEmpty)
    }
}
