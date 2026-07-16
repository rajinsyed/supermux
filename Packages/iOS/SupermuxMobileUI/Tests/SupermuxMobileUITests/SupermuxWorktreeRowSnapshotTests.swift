import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileUI
import Testing

/// Pure-value projection of wire worktrees onto phone rows: branch/path
/// display fallback, dirty/open state, and PR badge mapping (state-colored
/// number badge — number + state only, no title, matching the desktop badge).
@Suite struct SupermuxWorktreeRowSnapshotTests {
    @Test func projectsBranchDirtyOpenAndPullRequest() {
        let dto = SupermuxWorktreeDTO(
            path: "/Users/dev/alpha/.worktrees/fix-login",
            branch: "fix-login",
            isOpen: true,
            workspaceId: "5D2C9A44-71B3-4F0E-8E0A-6C4D1F2B3A55",
            isDirty: true,
            pullRequest: SupermuxPullRequestDTO(
                number: 41,
                state: "open",
                url: "https://github.com/acme/app/pull/41",
                isStale: true
            )
        )
        let row = SupermuxWorktreeRowSnapshot(worktree: dto)
        #expect(row.id == dto.path)
        #expect(row.displayName == "fix-login")
        #expect(row.isDirty)
        #expect(row.isOpen)
        #expect(row.workspaceID == "5D2C9A44-71B3-4F0E-8E0A-6C4D1F2B3A55")
        #expect(row.pullRequest?.number == 41)
        #expect(row.pullRequest?.state == .open)
        #expect(row.pullRequest?.url == URL(string: "https://github.com/acme/app/pull/41"))
        // is_stale rides the same DTO and dims the badge like the mac's.
        #expect(row.pullRequest?.isStale == true)
    }

    @Test func optionalFieldsDegradeToSafeDefaults() {
        // Optional-first wire contract: everything but the path may be
        // absent (m1 scrutiny fact) — the row must nil-handle.
        let row = SupermuxWorktreeRowSnapshot(
            worktree: SupermuxWorktreeDTO(path: "/Users/dev/alpha/.worktrees/new-idea")
        )
        #expect(row.displayName == "new-idea")
        #expect(!row.isDirty)
        #expect(!row.isOpen)
        #expect(row.workspaceID == nil)
        #expect(row.pullRequest == nil)
    }

    @Test func pullRequestStateMapsToTheDesktopBadgeStates() {
        func state(_ raw: String?) -> SupermuxPullRequestBadgeState {
            SupermuxPullRequestBadgeState(state: raw)
        }
        #expect(state("open") == .open)
        #expect(state("merged") == .merged)
        #expect(state("closed") == .closed)
        // Unknown future spellings degrade to a neutral badge, never a crash.
        #expect(state("draft") == .unknown)
        #expect(state(nil) == .unknown)
    }

    @Test func pullRequestBadgeToleratesAMissingOrGarbageURL() {
        let missing = SupermuxPullRequestBadgeSnapshot(
            dto: SupermuxPullRequestDTO(number: 7, state: "merged")
        )
        #expect(missing?.number == 7)
        #expect(missing?.state == .merged)
        #expect(missing?.url == nil)
    }

    @Test func rowsPreserveTheMacsOrder() {
        let rows = SupermuxWorktreeRowSnapshot.rows(from: [
            SupermuxWorktreeDTO(path: "/w/b-two", branch: "b-two"),
            SupermuxWorktreeDTO(path: "/w/a-one", branch: "a-one"),
        ])
        #expect(rows.map(\.displayName) == ["b-two", "a-one"])
    }
}
