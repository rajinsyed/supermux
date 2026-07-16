import CmuxMobileShellModel
import Foundation
import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// The phone-side consumers of the §6 workspace-list augmentation: the
/// flat-list hide filter, the preview → nested-workspace-row mapping, and the
/// section model's open-workspace join (count badges + project-detail rows +
/// the selectWorkspace routing).
@MainActor
@Suite struct SupermuxWorkspaceAugmentationTests {
    private static let projectID = "66666666-6666-6666-6666-666666666666"

    private func preview(
        id: String,
        name: String = "ws",
        groupID: String? = nil,
        supermuxProjectID: String? = nil,
        supermuxActivity: String? = nil,
        hasUnread: Bool = false
    ) -> MobileWorkspacePreview {
        var preview = MobileWorkspacePreview(
            id: MobileWorkspacePreview.ID(rawValue: id),
            name: name,
            groupID: groupID.map { MobileWorkspaceGroupPreview.ID(rawValue: $0) },
            hasUnread: hasUnread,
            terminals: []
        )
        preview.supermuxProjectID = supermuxProjectID
        preview.supermuxActivity = supermuxActivity
        return preview
    }

    // MARK: Flat-list hide filter

    @Test func hideFilterDropsOnlyUngroupedProjectAssociatedRows() {
        let standalone = preview(id: "a")
        let associated = preview(id: "b", supermuxProjectID: Self.projectID)
        let groupedAssociated = preview(id: "c", groupID: "g1", supermuxProjectID: Self.projectID)

        let rows = [standalone, associated, groupedAssociated]
            .supermuxFlatRows(hidingProjectIDs: [Self.projectID])

        // Mirrors the Mac's flat-list filter: only LOOSE project-owned
        // workspaces fold under their project; cmux-grouped ones stay with
        // their group section.
        #expect(rows.map(\.id.rawValue) == ["a", "c"])
    }

    @Test func hideFilterIsInertWhenDisabled() {
        let associated = preview(id: "b", supermuxProjectID: Self.projectID)
        let rows = [associated].supermuxFlatRows(hidingProjectIDs: [])
        #expect(rows.map(\.id.rawValue) == ["b"])
    }

    @Test func hideFilterKeepsWorkspacesWhoseProjectIsNotShown() {
        // Regression: a project-associated workspace whose owning project is
        // NOT a row in the section (a second paired Mac's workspace, or any
        // workspace before projects.list loads) must stay in the flat list —
        // hiding it there would make it unreachable, since it has no project
        // row to expand under. Only ids present in the shown set fold away.
        let shown = preview(id: "a", supermuxProjectID: Self.projectID)
        let orphan = preview(id: "b", supermuxProjectID: "99999999-9999-9999-9999-999999999999")

        let rows = [shown, orphan].supermuxFlatRows(hidingProjectIDs: [Self.projectID])

        #expect(rows.map(\.id.rawValue) == ["b"])
    }

    // MARK: Preview → nested-row mapping

    @Test func nestedRowMappingKeepsOnlyAssociatedRowsAndParsesActivity() {
        let rows = SupermuxProjectWorkspaceRowSnapshot.rows(from: [
            preview(id: "a"),
            preview(id: "b", name: "alpha main", supermuxProjectID: Self.projectID, supermuxActivity: "needs_input", hasUnread: true),
            preview(id: "c", name: "alpha wt", supermuxProjectID: Self.projectID, supermuxActivity: "not-a-state"),
        ])

        #expect(rows.map(\.id) == ["b", "c"])
        #expect(rows[0].projectID == Self.projectID)
        #expect(rows[0].name == "alpha main")
        #expect(rows[0].activity == .needsInput)
        #expect(rows[0].hasUnread)
        // Unknown future activity spellings degrade to "no dot", never a crash.
        #expect(rows[1].activity == nil)
        #expect(!rows[1].hasUnread)
    }

    // MARK: Section model join

    @Test func updateWorkspacesPopulatesOpenWorkspaceCountAndDetailRows() async throws {
        let wait = TestWait()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [
            SupermuxProjectDTO(id: Self.projectID, name: "Alpha", rootPath: "/Users/dev/alpha"),
            SupermuxProjectDTO(id: "77777777-7777-7777-7777-777777777777", name: "Beta", rootPath: "/Users/dev/beta"),
        ])
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [SupermuxMobileCapability.projectsV1.rawValue]
            )
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.rows.count == 2 }

        model.updateWorkspaces(
            SupermuxProjectWorkspaceRowSnapshot.rows(from: [
                preview(id: "w1", name: "alpha main", supermuxProjectID: Self.projectID, supermuxActivity: "working"),
                preview(id: "w2", name: "alpha wt", supermuxProjectID: Self.projectID),
                preview(id: "w3", name: "standalone"),
            ]),
            selectWorkspace: { _ in }
        )

        let alpha = try #require(model.snapshot.rows.first { $0.id == Self.projectID })
        #expect(alpha.openWorkspaceCount == 2)
        #expect(alpha.openWorkspaces.map(\.name) == ["alpha main", "alpha wt"])
        #expect(alpha.openWorkspaces.map(\.activity) == [.working, nil])

        // A project with no open workspaces renders no badge (nil, never 0).
        let beta = try #require(model.snapshot.rows.first { $0.name == "Beta" })
        #expect(beta.openWorkspaceCount == nil)
        #expect(beta.openWorkspaces.isEmpty)
    }

    @Test func actionsRouteSelectWorkspaceToTheLatestClosure() async throws {
        let model = SupermuxProjectsSectionModel()
        var selected: [String] = []
        model.updateWorkspaces([], selectWorkspace: { selected.append($0) })

        model.actions.selectWorkspace("w42")

        #expect(selected == ["w42"])
    }

    // MARK: m6-f2 row parity — branch / PR / remote id mapping

    @Test func nestedRowMappingCarriesBranchPullRequestAndRemoteID() throws {
        var full = preview(id: "mac1:w1", name: "alpha main", supermuxProjectID: Self.projectID)
        full.remoteWorkspaceID = MobileWorkspacePreview.ID(rawValue: "w1")
        full.supermuxBranch = "  feature/parity  "
        full.supermuxPullRequestNumber = 4321
        full.supermuxPullRequestState = "merged"
        full.supermuxPullRequestURL = "https://github.com/acme/alpha/pull/4321"
        full.supermuxPullRequestIsStale = true

        var bare = preview(id: "w2", name: "alpha wt", supermuxProjectID: Self.projectID)
        bare.supermuxBranch = "   "

        let rows = SupermuxProjectWorkspaceRowSnapshot.rows(from: [full, bare])
        try #require(rows.count == 2)

        // Full row: trimmed branch, badge snapshot, Mac-local remote id.
        #expect(rows[0].branch == "feature/parity")
        #expect(rows[0].remoteID == "w1")
        let badge = try #require(rows[0].pullRequest)
        #expect(badge.number == 4321)
        #expect(badge.state == .merged)
        #expect(badge.url?.absoluteString == "https://github.com/acme/alpha/pull/4321")
        #expect(badge.isStale)
        // rows(from:) never marks running — the section model stamps it.
        #expect(!rows[0].isRunning)

        // Bare row: blank branch degrades to nil, no badge, remote id falls
        // back to the UI row id.
        #expect(rows[1].branch == nil)
        #expect(rows[1].pullRequest == nil)
        #expect(rows[1].remoteID == "w2")
    }

    @Test func runStateMarksTheHostingNestedWorkspaceRow() async throws {
        let wait = TestWait()
        let client = FakeSupermuxMacClient()
        client.listResponse = SupermuxProjectsListResponse(projects: [
            SupermuxProjectDTO(
                id: Self.projectID,
                name: "Alpha",
                rootPath: "/Users/dev/alpha",
                runCommands: ["pnpm dev"]
            ),
        ])
        // The run.state row points at the hosting workspace by Mac-local id;
        // a lowercased wire spelling must still match (UUIDs are
        // case-insensitive).
        client.runStateResponse = SupermuxRunStateResponse(runs: [
            SupermuxRunStateDTO(
                projectId: Self.projectID,
                isRunning: true,
                command: "pnpm dev",
                workspaceId: "aaaa1111-2222-3333-4444-555566667777"
            ),
        ])
        let model = SupermuxProjectsSectionModel()
        let session = Task {
            await model.runSession(
                client: client,
                hostCapabilities: [
                    SupermuxMobileCapability.projectsV1.rawValue,
                    SupermuxMobileCapability.runV1.rawValue,
                ]
            )
        }
        defer { session.cancel() }
        try await wait.until { model.snapshot.hasLoaded }

        var host = preview(id: "mac1:AAAA1111-2222-3333-4444-555566667777", name: "alpha run", supermuxProjectID: Self.projectID)
        host.remoteWorkspaceID = MobileWorkspacePreview.ID(rawValue: "AAAA1111-2222-3333-4444-555566667777")
        let other = preview(id: "w2", name: "alpha other", supermuxProjectID: Self.projectID)
        model.updateWorkspaces(
            SupermuxProjectWorkspaceRowSnapshot.rows(from: [host, other]),
            selectWorkspace: { _ in }
        )

        try await wait.until {
            model.snapshot.rows.first?.openWorkspaces.first?.isRunning == true
        }
        let alpha = try #require(model.snapshot.rows.first)
        #expect(alpha.openWorkspaces.map(\.isRunning) == [true, false])
    }
}
