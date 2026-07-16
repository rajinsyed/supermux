import SupermuxMobileCore
@testable import SupermuxMobileUI
import Testing

/// History-row projection: wire commits map to immutable row values with
/// graceful degradation for absent fields and the `is_pushed == false`
/// unpushed marker (UI-04's rendering side).
@Suite struct SupermuxCommitRowSnapshotTests {
    @Test func projectsAFullCommitPreservingOrder() {
        let rows = SupermuxCommitRowSnapshot.rows(from: [
            SupermuxCommitDTO(
                sha: String(repeating: "a", count: 40),
                shortSha: "aaaaaaa",
                author: "Supermux Tests",
                relativeDate: "2 hours ago",
                subject: "feat: mobile commit",
                isPushed: false
            ),
            SupermuxCommitDTO(
                sha: String(repeating: "b", count: 40),
                shortSha: "bbbbbbb",
                author: "Supermux Tests",
                relativeDate: "3 days ago",
                subject: "Initial commit",
                isPushed: true
            ),
        ])
        #expect(rows.count == 2)
        #expect(rows[0].id == String(repeating: "a", count: 40))
        #expect(rows[0].subject == "feat: mobile commit")
        #expect(rows[0].shortSha == "aaaaaaa")
        #expect(rows[0].author == "Supermux Tests")
        #expect(rows[0].relativeDate == "2 hours ago")
        #expect(rows[0].isUnpushed)
        #expect(!rows[1].isUnpushed)
    }

    @Test func degradesGracefullyWhenOptionalFieldsAreAbsent() {
        let row = SupermuxCommitRowSnapshot(
            dto: SupermuxCommitDTO(sha: "0123456789abcdef0123456789abcdef01234567")
        )
        // shortSha falls back to the sha's first seven characters; a missing
        // subject renders an em dash rather than an empty row.
        #expect(row.shortSha == "0123456")
        #expect(row.subject == "—")
        #expect(row.author == nil)
        #expect(row.relativeDate == nil)
        // An absent `is_pushed` gets no unpushed styling (m3-f2's probe cap
        // degrades deep never-pushed history toward pushed).
        #expect(!row.isUnpushed)
    }

    @Test func blankSubjectAndShortShaFallBackLikeAbsentOnes() {
        let row = SupermuxCommitRowSnapshot(dto: SupermuxCommitDTO(
            sha: "fedcba9876543210fedcba9876543210fedcba98",
            shortSha: "  ",
            subject: " \n",
            isPushed: true
        ))
        #expect(row.shortSha == "fedcba9")
        #expect(row.subject == "—")
        #expect(!row.isUnpushed)
    }
}
