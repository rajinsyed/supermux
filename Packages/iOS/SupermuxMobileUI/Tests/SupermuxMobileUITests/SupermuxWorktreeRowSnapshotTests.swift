import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileUI
import Testing

/// Pure-value projection of wire worktrees onto phone rows: branch/path
/// display fallback and dirty/open state.
@Suite struct SupermuxWorktreeRowSnapshotTests {
    @Test func projectsBranchDirtyAndOpen() {
        let dto = SupermuxWorktreeDTO(
            path: "/Users/dev/alpha/.worktrees/fix-login",
            branch: "fix-login",
            isOpen: true,
            workspaceId: "5D2C9A44-71B3-4F0E-8E0A-6C4D1F2B3A55",
            isDirty: true
        )
        let row = SupermuxWorktreeRowSnapshot(worktree: dto)
        #expect(row.id == dto.path)
        #expect(row.displayName == "fix-login")
        #expect(row.isDirty)
        #expect(row.isOpen)
        #expect(row.workspaceID == "5D2C9A44-71B3-4F0E-8E0A-6C4D1F2B3A55")
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
    }

    @Test func rowsPreserveTheMacsOrder() {
        let rows = SupermuxWorktreeRowSnapshot.rows(from: [
            SupermuxWorktreeDTO(path: "/w/b-two", branch: "b-two"),
            SupermuxWorktreeDTO(path: "/w/a-one", branch: "a-one"),
        ])
        #expect(rows.map(\.displayName) == ["b-two", "a-one"])
    }
}
