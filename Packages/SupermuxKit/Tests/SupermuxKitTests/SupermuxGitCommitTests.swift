import Foundation
import Testing

import SupermuxKit

/// Unit tests for ``SupermuxGitCommit/parse(log:)`` against the NUL-separated
/// stream that `git log -z --format=\(SupermuxGitCommit.logFormat)` produces.
@Suite struct SupermuxGitCommitTests {

    /// Builds output shaped like `git log -z`: five `%x00`-separated fields per
    /// commit, each record terminated by a trailing NUL.
    private func gitLogOutput(_ commits: [(String, String, String, String, String)]) -> String {
        commits.map { commit in
            [commit.0, commit.1, commit.2, commit.3, commit.4]
                .joined(separator: "\u{0}") + "\u{0}"
        }.joined()
    }

    @Test func parsesMultipleCommitsInOrder() {
        let output = gitLogOutput([
            ("aaaa1111", "aaaa1", "Ada Lovelace", "2 hours ago", "Add the thing"),
            ("bbbb2222", "bbbb2", "Alan Turing", "3 days ago", "Fix the bug"),
        ])

        let commits = SupermuxGitCommit.parse(log: output)

        #expect(commits.count == 2)
        #expect(commits[0].hash == "aaaa1111")
        #expect(commits[0].shortHash == "aaaa1")
        #expect(commits[0].author == "Ada Lovelace")
        #expect(commits[0].relativeDate == "2 hours ago")
        #expect(commits[0].subject == "Add the thing")
        #expect(commits[1].hash == "bbbb2222")
        #expect(commits[1].subject == "Fix the bug")
    }

    @Test func parsesEmptyOutputAsNoCommits() {
        #expect(SupermuxGitCommit.parse(log: "").isEmpty)
    }

    @Test func preservesEmptySubject() {
        let output = gitLogOutput([("hash", "h", "Name", "now", "")])

        let commits = SupermuxGitCommit.parse(log: output)

        #expect(commits.count == 1)
        #expect(commits[0].subject == "")
    }

    /// NUL framing means a field may contain spaces or even newlines without
    /// breaking parsing — the property that motivates the `-z` format.
    @Test func preservesSpacesAndNewlinesWithinFields() {
        let output = gitLogOutput([
            ("hash", "h", "First Last", "now", "line one\nstill the subject  with spaces"),
        ])

        let commits = SupermuxGitCommit.parse(log: output)

        #expect(commits[0].author == "First Last")
        #expect(commits[0].subject == "line one\nstill the subject  with spaces")
    }

    @Test func skipsTrailingIncompleteRecord() {
        // A complete record followed by a truncated one (fewer than five fields).
        let output = "hash\u{0}h\u{0}Name\u{0}now\u{0}subject\u{0}leftover\u{0}partial"

        let commits = SupermuxGitCommit.parse(log: output)

        #expect(commits.count == 1)
        #expect(commits[0].hash == "hash")
    }
}
