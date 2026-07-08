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
            .supermuxFlatRows(hidingProjectAssociated: true)

        // Mirrors the Mac's flat-list filter: only LOOSE project-owned
        // workspaces fold under their project; cmux-grouped ones stay with
        // their group section.
        #expect(rows.map(\.id.rawValue) == ["a", "c"])
    }

    @Test func hideFilterIsInertWhenDisabled() {
        let associated = preview(id: "b", supermuxProjectID: Self.projectID)
        let rows = [associated].supermuxFlatRows(hidingProjectAssociated: false)
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
}
