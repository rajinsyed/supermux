import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileUI
import Testing

/// ``SupermuxProjectMobileAvatar`` keys its icon-refetch `.task(id:)` on
/// ``SupermuxProjectIconIdentity`` — project id + `hasCustomIcon` + the
/// icon's content etag — rather than the whole row snapshot, so unrelated
/// row changes (branch subtitle, expansion, counts, run state, …) never
/// re-issue `project.icon` or re-decode the PNG, while a REAL icon change
/// (replaced image bytes with `hasCustomIcon` still `true`, which moves the
/// etag) does re-run the fetch instead of rendering stale forever.
@Suite struct SupermuxProjectMobileAvatarTests {
    private func dto(
        id: String = "11111111-1111-1111-1111-111111111111",
        hasCustomIcon: Bool? = true
    ) -> SupermuxProjectDTO {
        SupermuxProjectDTO(
            id: id,
            name: "Alpha",
            rootPath: "/Users/dev/alpha",
            hasCustomIcon: hasCustomIcon
        )
    }

    private func identity(of row: SupermuxProjectRowSnapshot) -> SupermuxProjectIconIdentity {
        SupermuxProjectIconIdentity(
            projectID: row.id,
            hasCustomIcon: row.hasCustomIcon,
            iconETag: row.iconETag
        )
    }

    @Test func identityIsEqualAcrossUnrelatedRowChanges() {
        let base = SupermuxProjectRowSnapshot(project: dto(), iconETag: "etag-1")
        let expanded = SupermuxProjectRowSnapshot(
            project: dto(),
            worktreeCount: 4,
            iconETag: "etag-1",
            run: SupermuxProjectRunState(isRunning: true, command: "npm run dev"),
            isExpanded: true,
            nestedWorktrees: .loading
        )

        #expect(
            identity(of: base) == identity(of: expanded),
            "unrelated row changes must not change the icon identity"
        )
    }

    @Test func identityChangesWhenTheIconContentETagChanges() {
        // The regression this pins: a Mac-side icon REPLACEMENT keeps the
        // project id and `hasCustomIcon == true` unchanged — only the
        // content etag moves. The identity must move with it, or the
        // avatar's `.task(id:)` never re-runs and the stale icon renders
        // indefinitely.
        let before = SupermuxProjectRowSnapshot(project: dto(), iconETag: "etag-1")
        let after = SupermuxProjectRowSnapshot(project: dto(), iconETag: "etag-2")
        #expect(before.hasCustomIcon == after.hasCustomIcon)
        #expect(before.id == after.id)
        #expect(identity(of: before) != identity(of: after))

        // nil → etag (the wire starting to surface the signal) also re-keys.
        let unknown = SupermuxProjectRowSnapshot(project: dto(), iconETag: nil)
        #expect(identity(of: unknown) != identity(of: before))
    }

    @Test func identityChangesWhenTheProjectChanges() {
        let alpha = SupermuxProjectRowSnapshot(project: dto(id: "11111111-1111-1111-1111-111111111111"))
        let beta = SupermuxProjectRowSnapshot(project: dto(id: "22222222-2222-2222-2222-222222222222"))
        #expect(identity(of: alpha) != identity(of: beta))
    }

    @Test func identityChangesWhenTheCustomIconFlagFlips() {
        let withIcon = SupermuxProjectRowSnapshot(project: dto(hasCustomIcon: true))
        let withoutIcon = SupermuxProjectRowSnapshot(project: dto(hasCustomIcon: false))
        #expect(identity(of: withIcon) != identity(of: withoutIcon))
    }
}
