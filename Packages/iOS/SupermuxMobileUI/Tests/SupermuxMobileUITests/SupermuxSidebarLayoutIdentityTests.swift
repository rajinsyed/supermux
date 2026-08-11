import Foundation
import SupermuxMobileCore
@testable import SupermuxMobileUI
import Testing

/// ``SupermuxProjectsTableLayoutIdentity`` decides when the hosting UIKit cell
/// re-measures the whole Projects subtree. Getting it wrong is expensive in
/// both directions and silent in both: too eager pushes the entire section
/// through `systemLayoutSizeFitting` on every agent tick, too lazy leaves the
/// section clipped or padded at a stale height with no visible error.
///
/// The redesign changed which fields are load-bearing, so these pin the new
/// contract:
///
/// - the worktree PILL is presence-only (a count change never resizes it),
/// - a nested workspace row's height depends on whether it has a BRANCH,
/// - and the paint-level fields the row no longer renders as text (run state,
///   activity, PR badges) must not re-measure at all.
@Suite struct SupermuxSidebarLayoutIdentityTests {
    private func dto(
        id: String = "11111111-1111-1111-1111-111111111111",
        name: String = "Alpha",
        runCommands: [String]? = nil
    ) -> SupermuxProjectDTO {
        SupermuxProjectDTO(
            id: id,
            name: name,
            rootPath: "/Users/dev/alpha",
            runCommands: runCommands
        )
    }

    private func workspace(
        id: String = "w1",
        branch: String? = nil,
        activity: SupermuxWorkspaceActivityDTO? = nil,
        hasUnread: Bool = false,
        isRunning: Bool = false
    ) -> SupermuxProjectWorkspaceRowSnapshot {
        SupermuxProjectWorkspaceRowSnapshot(
            id: id,
            projectID: "11111111-1111-1111-1111-111111111111",
            name: "Workspace",
            activity: activity,
            hasUnread: hasUnread,
            branch: branch,
            isRunning: isRunning
        )
    }

    private func section(rows: [SupermuxProjectRowSnapshot]) -> SupermuxProjectsSectionSnapshot {
        SupermuxProjectsSectionSnapshot(
            isVisible: true,
            isCollapsed: false,
            hasLoaded: true,
            rows: rows
        )
    }

    private func fingerprint(_ rows: [SupermuxProjectRowSnapshot], canEdit: Bool = true) -> String {
        SupermuxProjectsTableLayoutIdentity(section: section(rows: rows), canEdit: canEdit).fingerprint
    }

    @Test func liveStatusChangesNeverReMeasureTheSection() {
        // Everything here repaints a row at EXACTLY the same size: the run dot,
        // the agent-activity dot, and the unread dot are all fixed-size glyphs
        // in the trailing cluster. During live agent output these change
        // constantly, which is the whole reason the height identity exists.
        let idle = SupermuxProjectRowSnapshot(
            project: dto(runCommands: ["bun dev"]),
            openWorkspaces: [workspace(branch: "main")],
            run: SupermuxProjectRunState(isRunning: false)
        )
        let busy = SupermuxProjectRowSnapshot(
            project: dto(runCommands: ["bun dev"]),
            openWorkspaces: [workspace(
                branch: "main",
                activity: .working,
                hasUnread: true,
                isRunning: true
            )],
            run: SupermuxProjectRunState(isRunning: true, command: "bun dev")
        )
        #expect(fingerprint([idle]) == fingerprint([busy]))
    }

    @Test func theWorktreePillIsPresenceOnly() {
        // The pill is a fixed-height capsule, so 2 → 17 worktrees does not
        // change the row's height — but 0 → 1 makes the pill appear.
        let none = SupermuxProjectRowSnapshot(project: dto(), worktreeCount: 0)
        let two = SupermuxProjectRowSnapshot(project: dto(), worktreeCount: 2)
        let seventeen = SupermuxProjectRowSnapshot(project: dto(), worktreeCount: 17)

        #expect(fingerprint([two]) == fingerprint([seventeen]))
        #expect(fingerprint([none]) != fingerprint([two]))

        // An unknown count (no worktrees fetch yet) renders no pill, exactly
        // like a known zero.
        let unknown = SupermuxProjectRowSnapshot(project: dto(), worktreeCount: nil)
        #expect(fingerprint([unknown]) == fingerprint([none]))
    }

    @Test func aNestedWorkspacesBranchChangesItsHeight() {
        // A branch adds the row's monospaced second line. Missing this would
        // clip the branch under the next row.
        let bare = SupermuxProjectRowSnapshot(
            project: dto(),
            openWorkspaces: [workspace(branch: nil)]
        )
        let branched = SupermuxProjectRowSnapshot(
            project: dto(),
            openWorkspaces: [workspace(branch: "feature/x")]
        )
        #expect(fingerprint([bare]) != fingerprint([branched]))

        // The branch's SPELLING does not: it is a one-line truncating label.
        let renamed = SupermuxProjectRowSnapshot(
            project: dto(),
            openWorkspaces: [workspace(branch: "some-other-branch")]
        )
        #expect(fingerprint([branched]) == fingerprint([renamed]))
    }

    @Test func structuralChangesDoReMeasure() {
        let collapsed = SupermuxProjectRowSnapshot(project: dto(), isExpanded: false)
        let expanded = SupermuxProjectRowSnapshot(
            project: dto(),
            isExpanded: true,
            nestedWorktrees: .loaded([])
        )
        let loading = SupermuxProjectRowSnapshot(
            project: dto(),
            isExpanded: true,
            nestedWorktrees: .loading
        )
        #expect(fingerprint([collapsed]) != fingerprint([expanded]))
        #expect(fingerprint([expanded]) != fingerprint([loading]))

        // Row count and order both move rows on screen.
        let other = SupermuxProjectRowSnapshot(
            project: dto(id: "22222222-2222-2222-2222-222222222222", name: "Beta")
        )
        #expect(fingerprint([collapsed]) != fingerprint([collapsed, other]))
        #expect(fingerprint([collapsed, other]) != fingerprint([other, collapsed]))
    }

    @Test func aLongerNameReMeasuresButARenameOfEqualLengthDoesNot() {
        // The title truncates to one line, so only a length that could wrap
        // under a large Dynamic Type setting matters.
        let short = SupermuxProjectRowSnapshot(project: dto(name: "Alpha"))
        let sameLength = SupermuxProjectRowSnapshot(project: dto(name: "Gamma"))
        let long = SupermuxProjectRowSnapshot(
            project: dto(name: "A considerably longer project name")
        )
        #expect(fingerprint([short]) == fingerprint([sameLength]))
        #expect(fingerprint([short]) != fingerprint([long]))
    }

    @Test func hiddenCollapsedAndEmptyStatesEachHaveTheirOwnIdentity() {
        let row = SupermuxProjectRowSnapshot(project: dto())
        let hidden = SupermuxProjectsTableLayoutIdentity(section: .hidden, canEdit: true)
        let collapsed = SupermuxProjectsTableLayoutIdentity(
            section: SupermuxProjectsSectionSnapshot(
                isVisible: true, isCollapsed: true, hasLoaded: true, rows: [row]
            ),
            canEdit: true
        )
        let loading = SupermuxProjectsTableLayoutIdentity(
            section: SupermuxProjectsSectionSnapshot(
                isVisible: true, isCollapsed: false, hasLoaded: false, rows: []
            ),
            canEdit: true
        )
        let empty = SupermuxProjectsTableLayoutIdentity(
            section: SupermuxProjectsSectionSnapshot(
                isVisible: true, isCollapsed: false, hasLoaded: true, rows: []
            ),
            canEdit: true
        )
        let fingerprints = Set([
            hidden.fingerprint,
            collapsed.fingerprint,
            loading.fingerprint,
            empty.fingerprint,
            fingerprint([row]),
        ])
        #expect(fingerprints.count == 5, "each state must measure separately")
    }

    @Test func worktreeCreationAvailabilityAffectsHeight() {
        // The inline New Worktree row renders under every EXPANDED project on
        // a `supermux.worktrees.v1` host (and suppresses the empty notice),
        // so the capability's arrival must re-measure the section.
        let expanded = SupermuxProjectRowSnapshot(
            project: dto(),
            isExpanded: true,
            nestedWorktrees: .loaded([])
        )
        let without = SupermuxProjectsSectionSnapshot(
            isVisible: true, isCollapsed: false, hasLoaded: true, rows: [expanded]
        )
        let with = SupermuxProjectsSectionSnapshot(
            isVisible: true, isCollapsed: false, hasLoaded: true, rows: [expanded],
            showsWorktreeCreation: true
        )
        #expect(
            SupermuxProjectsTableLayoutIdentity(section: without, canEdit: true).fingerprint
                != SupermuxProjectsTableLayoutIdentity(section: with, canEdit: true).fingerprint
        )
    }

    @Test func theEditSeamAffectsHeightInEveryStateThatShowsAButton() {
        // The header's "+" and the empty state's Add Project button both exist
        // only with a live editing seam, and both change the measured height.
        let empty = SupermuxProjectsSectionSnapshot(
            isVisible: true, isCollapsed: false, hasLoaded: true, rows: []
        )
        #expect(
            SupermuxProjectsTableLayoutIdentity(section: empty, canEdit: true).fingerprint
                != SupermuxProjectsTableLayoutIdentity(section: empty, canEdit: false).fingerprint
        )
    }
}
